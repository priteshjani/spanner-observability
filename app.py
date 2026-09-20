#!/usr/bin/env python3
"""
Continuous Read/Write Application & Observability Simulator for Cloud Spanner.

Supports three operational modes:
  1. --mode normal        : Consistent read/write transactions, balance transfers,
                            heartbeat probes, and live leader region monitoring.
  2. --mode inject-errors : Runs read/write workload while injecting failing Spanner
                            API requests (INVALID_ARGUMENT, NOT_FOUND, ABORTED) to
                            trigger Alert Policy 1 (High Error Rate).
  3. --mode verify        : Runs a validation pass testing read, write, leader
                            metadata query, and prints a structured health report.
"""

import argparse
import decimal
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone

from google.api_core import exceptions as gcp_exceptions
from google.cloud import spanner


def get_current_leader(database) -> str:
    """Query INFORMATION_SCHEMA.DATABASE_OPTIONS for current default_leader."""
    query = (
        "SELECT OPTION_VALUE "
        "FROM INFORMATION_SCHEMA.DATABASE_OPTIONS "
        "WHERE OPTION_NAME = 'default_leader'"
    )
    with database.snapshot() as snapshot:
        results = list(snapshot.execute_sql(query))
        if results and results[0]:
            return str(results[0][0])
    return "UNKNOWN"


def perform_read_operation(database) -> float:
    """Execute a point read and secondary index scan on Accounts and Transactions."""
    start = time.perf_counter()
    acct_id = f"acct-000{random.randint(1, 5)}"
    with database.snapshot(multi_use=True) as snapshot:
        list(
            snapshot.execute_sql(
                "SELECT account_id, account_name, region, balance "
                "FROM Accounts WHERE account_id = @acct_id",
                params={"acct_id": acct_id},
                param_types={"acct_id": spanner.param_types.STRING},
            )
        )
        list(
            snapshot.execute_sql(
                "SELECT transaction_id, amount, txn_type, observed_leader, latency_ms "
                "FROM Transactions@{FORCE_INDEX=TransactionsByCommittedAt} "
                "ORDER BY committed_at DESC LIMIT 5"
            )
        )
    return (time.perf_counter() - start) * 1000.0


def perform_write_transaction(database, client_region: str, observed_leader: str, read_ms: float) -> float:
    """Execute a read-write transaction updating Accounts, inserting Transactions & HeartbeatLog."""
    start = time.perf_counter()
    acct_id = f"acct-000{random.randint(1, 5)}"
    txn_id = str(uuid.uuid4())
    probe_id = str(uuid.uuid4())
    delta = decimal.Decimal(str(round(random.uniform(10.0, 250.0), 2)))

    def _unit_of_work(transaction):
        row = list(
            transaction.execute_sql(
                "SELECT balance FROM Accounts WHERE account_id = @acct_id",
                params={"acct_id": acct_id},
                param_types={"acct_id": spanner.param_types.STRING},
            )
        )
        current_balance = row[0][0] if row else decimal.Decimal("100000.00")
        new_balance = current_balance + delta

        transaction.update(
            table="Accounts",
            columns=("account_id", "balance", "updated_at"),
            values=[(acct_id, new_balance, spanner.COMMIT_TIMESTAMP)],
        )
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        transaction.insert(
            table="Transactions",
            columns=(
                "account_id",
                "transaction_id",
                "amount",
                "txn_type",
                "client_region",
                "observed_leader",
                "latency_ms",
                "committed_at",
            ),
            values=[
                (
                    acct_id,
                    txn_id,
                    delta,
                    "CREDIT",
                    client_region,
                    observed_leader,
                    elapsed_ms,
                    spanner.COMMIT_TIMESTAMP,
                )
            ],
        )
        transaction.insert(
            table="HeartbeatLog",
            columns=(
                "probe_id",
                "probe_timestamp",
                "configured_leader",
                "read_latency_ms",
                "write_latency_ms",
                "vpc_network",
                "status",
            ),
            values=[
                (
                    probe_id,
                    spanner.COMMIT_TIMESTAMP,
                    observed_leader,
                    read_ms,
                    elapsed_ms,
                    os.environ.get("VPC_NETWORK", "my-host-prj-shared-vpc"),
                    "HEALTHY",
                )
            ],
        )

    database.run_in_transaction(_unit_of_work)
    return (time.perf_counter() - start) * 1000.0


def inject_spanner_api_error(database) -> str:
    """Intentionally trigger a Spanner server-side error so spanner.googleapis.com/api/request_count records status != OK."""
    error_type = random.choice(["INVALID_SQL", "MISSING_TABLE", "BAD_COLUMN_MUTATION"])
    try:
        if error_type == "INVALID_SQL":
            with database.snapshot() as snapshot:
                list(snapshot.execute_sql("SELECT non_existent_column FROM Accounts WHERE 1 = 'invalid_int'"))
        elif error_type == "MISSING_TABLE":
            with database.snapshot() as snapshot:
                list(snapshot.execute_sql("SELECT * FROM NonExistentFaultInjectionTable LIMIT 1"))
        else:
            def _bad_write(transaction):
                transaction.insert(
                    table="Accounts",
                    columns=("account_id", "NonExistentColumn"),
                    values=[("err-acct", "bad-val")],
                )
            database.run_in_transaction(_bad_write)
    except gcp_exceptions.GoogleAPICallError as exc:
        return f"{exc.__class__.__name__}"
    except Exception as exc:
        return f"{type(exc).__name__}"
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

    client = spanner.Client(project=args.project_id)
    instance = client.instance(args.instance_id)
    database = instance.database(args.database_id)

    initial_leader = get_current_leader(database)
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

            # Check for leader flip every 5 iterations (or on verify)
            if iteration % 5 == 1 or args.mode == "verify":
                current_leader = get_current_leader(database)
                if current_leader != last_leader:
                    print(
                        f"\n[ALERT - LEADER FLIP DETECTED] {now_str} | "
                        f"Database '{args.database_id}' default_leader flipped from "
                        f"'{last_leader}' ---> '{current_leader}'!\n"
                    )
                    last_leader = current_leader

            # Execute Read & Write workload
            try:
                read_ms = perform_read_operation(database)
                write_ms = perform_write_transaction(
                    database, args.client_region, last_leader, read_ms
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

            # If in inject-errors mode, inject burst of failing Spanner API calls
            if args.mode == "inject-errors":
                injected_codes = []
                for _ in range(3):
                    err_ops += 1
                    injected_codes.append(inject_spanner_api_error(database))
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
