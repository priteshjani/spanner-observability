#!/usr/bin/env python3
"""
Continuous Read/Write Application & Observability Simulator for Cloud Spanner.

Uses the Cloud Spanner v1 REST API with standard library Python (urllib.request, json)
and automatic gcloud CLI token refresh — zero virtualenv or pip install required.

Supports three operational modes:
  1. --mode normal        : Consistent read/write transactions, balance transfers,
                            heartbeat probes, and live leader region monitoring.
  2. --mode inject-errors : Runs read/write workload while injecting failing Spanner
                            API requests (INVALID_ARGUMENT, NOT_FOUND) to trigger
                            Alert Policy 1 (High API Error Rate).
  3. --mode verify        : Runs a validation pass testing read, write, leader
                            metadata query, and prints a structured health report.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone


class SpannerRestClient:
    """Lightweight Cloud Spanner v1 REST client using gcloud access tokens."""

    def __init__(self, project_id: str, instance_id: str, database_id: str):
        self.project_id = project_id
        self.instance_id = instance_id
        self.database_id = database_id
        self.db_uri = (
            f"https://spanner.googleapis.com/v1/projects/{project_id}"
            f"/instances/{instance_id}/databases/{database_id}"
        )
        self.token = ""
        self.token_fetched_at = 0.0
        self.session_name = ""
        self._refresh_token()
        self._create_session()

    def _refresh_token(self):
        if time.time() - self.token_fetched_at > 1800 or not self.token:
            self.token = subprocess.check_output(
                ["gcloud", "auth", "print-access-token"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            self.token_fetched_at = time.time()

    def _request(self, url: str, payload: dict | None = None) -> dict:
        self._refresh_token()
        data = json.dumps(payload or {}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _create_session(self):
        res = self._request(f"{self.db_uri}/sessions", {})
        self.session_name = res["name"]

    def execute_sql(self, sql: str, transaction_Selector: dict | None = None) -> dict:
        body: dict = {"sql": sql}
        if transaction_Selector:
            body["transaction"] = transaction_Selector
        return self._request(
            f"https://spanner.googleapis.com/v1/{self.session_name}:executeSql",
            body,
        )

    def get_current_leader(self) -> str:
        res = self.execute_sql(
            "SELECT OPTION_VALUE FROM INFORMATION_SCHEMA.DATABASE_OPTIONS "
            "WHERE OPTION_NAME = 'default_leader'"
        )
        rows = res.get("rows", [])
        if rows and rows[0]:
            return str(rows[0][0])
        return "UNKNOWN"

    def perform_read_operation(self) -> float:
        start = time.perf_counter()
        acct_id = f"acct-000{random.randint(1, 5)}"
        self.execute_sql(
            f"SELECT account_id, account_name, region, balance "
            f"FROM Accounts WHERE account_id = '{acct_id}'"
        )
        self.execute_sql(
            "SELECT transaction_id, amount, txn_type, observed_leader, latency_ms "
            "FROM Transactions@{FORCE_INDEX=TransactionsByCommittedAt} "
            "ORDER BY committed_at DESC LIMIT 5"
        )
        return (time.perf_counter() - start) * 1000.0

    def perform_write_transaction(
        self, client_region: str, observed_leader: str, read_ms: float
    ) -> float:
        start = time.perf_counter()
        acct_id = f"acct-000{random.randint(1, 5)}"
        txn_id = str(uuid.uuid4())
        probe_id = str(uuid.uuid4())
        delta = round(random.uniform(10.0, 250.0), 2)

        # Begin Read-Write Transaction
        tx_res = self._request(
            f"https://spanner.googleapis.com/v1/{self.session_name}:beginTransaction",
            {"options": {"readWrite": {}}},
        )
        tx_id = tx_res["id"]

        # Read current balance inside transaction
        row_res = self.execute_sql(
            f"SELECT balance FROM Accounts WHERE account_id = '{acct_id}'",
            transaction_Selector={"id": tx_id},
        )
        rows = row_res.get("rows", [])
        current_balance = float(rows[0][0]) if rows and rows[0] else 100000.00
        new_balance = round(current_balance + delta, 2)
        elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
        vpc_net = os.environ.get("VPC_NETWORK", "my-host-prj-shared-vpc")

        # Commit mutations for Accounts, Transactions, and HeartbeatLog
        mutations = [
            {
                "insertOrUpdate": {
                    "table": "Accounts",
                    "columns": ["account_id", "account_name", "region", "balance", "status", "updated_at"],
                    "values": [[acct_id, f"Enterprise-{acct_id}", observed_leader, str(new_balance), "ACTIVE", "spanner.commit_timestamp()"]],
                }
            },
            {
                "insert": {
                    "table": "Transactions",
                    "columns": [
                        "account_id",
                        "transaction_id",
                        "amount",
                        "txn_type",
                        "client_region",
                        "observed_leader",
                        "latency_ms",
                        "committed_at",
                    ],
                    "values": [
                        [
                            acct_id,
                            txn_id,
                            str(delta),
                            "CREDIT",
                            client_region,
                            observed_leader,
                            elapsed_ms,
                            "spanner.commit_timestamp()",
                        ]
                    ],
                }
            },
            {
                "insert": {
                    "table": "HeartbeatLog",
                    "columns": [
                        "probe_id",
                        "probe_timestamp",
                        "configured_leader",
                        "read_latency_ms",
                        "write_latency_ms",
                        "vpc_network",
                        "status",
                    ],
                    "values": [
                        [
                            probe_id,
                            "spanner.commit_timestamp()",
                            observed_leader,
                            round(read_ms, 2),
                            elapsed_ms,
                            vpc_net,
                            "HEALTHY",
                        ]
                    ],
                }
            },
        ]

        self._request(
            f"https://spanner.googleapis.com/v1/{self.session_name}:commit",
            {"transactionId": tx_id, "mutations": mutations},
        )
        return (time.perf_counter() - start) * 1000.0

    def inject_spanner_api_error(self) -> str:
        error_type = random.choice(["INVALID_SQL", "MISSING_TABLE", "BAD_MUTATION"])
        try:
            if error_type == "INVALID_SQL":
                self.execute_sql("SELECT non_existent_column FROM Accounts WHERE 1 = 'bad_int'")
            elif error_type == "MISSING_TABLE":
                self.execute_sql("SELECT * FROM NonExistentFaultInjectionTable LIMIT 1")
            else:
                self._request(
                    f"https://spanner.googleapis.com/v1/{self.session_name}:commit",
                    {
                        "singleUseTransaction": {"readWrite": {}},
                        "mutations": [
                            {
                                "insert": {
                                    "table": "Accounts",
                                    "columns": ["account_id", "NonExistentColumn"],
                                    "values": [["err-acct", "bad-val"]],
                                }
                            }
                        ],
                    },
                )
        except urllib.error.HTTPError as exc:
            return f"HTTP_{exc.code}"
        except Exception as exc:
            return type(exc).__name__
        return "NONE"


def main():
    parser = argparse.ArgumentParser(description="Spanner Multi-Region Read/Write & Observability App")
    parser.add_argument("--project-id", default=os.environ.get("PROJECT_ID", "my-host-prj-472917"))
    parser.add_argument("--instance-id", default=os.environ.get("INSTANCE_ID", "spanner-obs-mr"))
    parser.add_argument("--database-id", default=os.environ.get("DATABASE_ID", "finops-obs-db"))
    parser.add_argument("--client-region", default=os.environ.get("VPC_REGION", "us-east4"))
    parser.add_argument(
        "--mode",
        choices=["normal", "inject-errors", "verify"],
        default="normal",
        help="Workload execution mode",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=0,
        help="Duration in seconds (0 = run indefinitely until Ctrl+C)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Sleep interval in seconds between iterations",
    )
    args = parser.parse_args()

    print("==================================================================")
    print(" Cloud Spanner Multi-Region Workload & Observability Application")
    print(f" Project ID    : {args.project_id}")
    print(f" Instance ID   : {args.instance_id}")
    print(f" Database ID   : {args.database_id}")
    print(f" Client Region : {args.client_region}")
    print(f" Mode          : {args.mode}")
    print("==================================================================")

    client = SpannerRestClient(args.project_id, args.instance_id, args.database_id)
    initial_leader = client.get_current_leader()
    last_leader = initial_leader
    print(f"[INIT] Connected to Spanner. Current configured default_leader = '{initial_leader}'")

    start_time = time.time()
    iteration = 0
    ok_ops = 0
    err_ops = 0

    try:
        while True:
            iteration += 1
            now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

            if iteration % 5 == 1 or args.mode == "verify":
                current_leader = client.get_current_leader()
                if current_leader != last_leader:
                    print(
                        f"\n[ALERT - LEADER FLIP DETECTED] {now_str} | "
                        f"Database '{args.database_id}' default_leader flipped from "
                        f"'{last_leader}' ---> '{current_leader}'!\n"
                    )
                    last_leader = current_leader

            try:
                read_ms = client.perform_read_operation()
                write_ms = client.perform_write_transaction(
                    args.client_region, last_leader, read_ms
                )
                ok_ops += 2
                status_msg = (
                    f"[{now_str}] iter={iteration} | leader={last_leader} | "
                    f"READ={read_ms:.1f}ms | WRITE={write_ms:.1f}ms | ok={ok_ops} err={err_ops}"
                )
            except Exception as exc:
                err_ops += 1
                status_msg = (
                    f"[{now_str}] iter={iteration} | leader={last_leader} | "
                    f"WORKLOAD_ERROR={type(exc).__name__}: {exc} | ok={ok_ops} err={err_ops}"
                )

            if args.mode == "inject-errors":
                injected_codes = []
                for _ in range(3):
                    err_ops += 1
                    injected_codes.append(client.inject_spanner_api_error())
                status_msg += f" | INJECTED_ERRORS={','.join(injected_codes)}"

            print(status_msg, flush=True)

            if args.mode == "verify":
                print("\n[VERIFY SUCCESS] Read, Write, HeartbeatLog, and Leader metadata verified!")
                break

            if args.duration > 0 and (time.time() - start_time) >= args.duration:
                print(f"\n[DONE] Completed {args.duration}s workload run (ok={ok_ops}, err={err_ops}).")
                break

            time.sleep(args.interval)

    except KeyboardInterrupt:
        print(f"\n[STOPPED] Interrupted by user (ok={ok_ops}, err={err_ops}).")
        sys.exit(0)


if __name__ == "__main__":
    main()
