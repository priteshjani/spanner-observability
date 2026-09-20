# Cloud Spanner Multi-Region Availability & Observability Demo (`spanner-observability`)

End-to-end demonstration of **Cloud Spanner Multi-Region High Availability, Continuous Read/Write Workload Generation, and Proactive Observability/Alerting** in Google Cloud.

---

## Environment Configuration

| Parameter | Value |
| :--- | :--- |
| **Project ID** | `my-host-prj-472917` |
| **Project Name** | `my-host-prj` |
| **VPC Network** | `my-host-prj-shared-vpc` |
| **Spanner Instance** | `spanner-obs-mr` (`nam3` Multi-Region: `us-east4`, `us-east1`, `us-central1`) |
| **Edition** | `ENTERPRISE_PLUS` (1000 Processing Units) |
| **Database ID** | `finops-obs-db` |
| **Primary Default Leader** | `us-east4` (Northern Virginia) |
| **Alternate Failover Leader** | `us-east1` (South Carolina) |
| **Notification Channels** | `priteshjani@priteshjani.altostrat.com`, `priteshjani@google.com` |

---

## Repository Structure

* [`config.env`](./config.env) — Central configuration variables (Project ID, Shared VPC, Multi-Region Spanner config, Notification channel emails).
* [`01_setup_spanner.sh`](./01_setup_spanner.sh) — Enables required GCP APIs, verifies `my-host-prj-shared-vpc`, and creates the multi-region (`nam3`) Cloud Spanner instance.
* [`schema.sql`](./schema.sql) — Multi-region DDL schema (`Accounts`, `Transactions`, `HeartbeatLog`) with `default_leader = 'us-east4'`.
* [`02_setup_database.sh`](./02_setup_database.sh) — Creates `finops-obs-db`, configures the multi-region leader option, and seeds initial enterprise accounts.
* [`03_setup_observability_alerts.sh`](./03_setup_observability_alerts.sh) — Creates Cloud Monitoring Email Notification Channels (`priteshjani@priteshjani.altostrat.com`, `priteshjani@google.com`), log-based metrics, two Alert Policies (Error Rate + Multi-Region Leader Flip), and a Cloud Monitoring Dashboard.
* [`app.py`](./app.py) — Python workload generator that continuously runs point reads, secondary index queries, read-write balance transfer transactions, and live `default_leader` monitoring.
* [`04_trigger_error_rate_scenario.sh`](./04_trigger_error_rate_scenario.sh) — **Demo Scenario 1**: Injects non-OK Spanner API calls (`INVALID_ARGUMENT`, `NOT_FOUND`) alongside normal traffic to trigger the **Spanner High API Error Rate** email alert.
* [`05_trigger_leader_flip_scenario.sh`](./05_trigger_leader_flip_scenario.sh) — **Demo Scenario 2**: Flips the multi-region Spanner database leader between `us-east4` and `us-east1` to trigger the **Spanner Multi-Region Leader Flip** email alerts and live application detection.
* [`06_validate_all.sh`](./06_validate_all.sh) — End-to-end validation script verifying the Spanner instance, database leader configuration, notification channels, alert policies, and read/write application probes.
* [`07_cleanup.sh`](./07_cleanup.sh) — Clean teardown script for post-demo cleanup.

---

## Step-by-Step Demo Execution Guide

### 1. Provision Multi-Region Spanner Instance & Database
```bash
./01_setup_spanner.sh
./02_setup_database.sh
```

### 2. Configure Email Notification Channels, Alerts & Dashboard
```bash
./03_setup_observability_alerts.sh
```
> **Note**: Check both `priteshjani@priteshjani.altostrat.com` and `priteshjani@google.com` inboxes to confirm any initial Cloud Monitoring channel verification emails if prompted.

### 3. Start Continuous Read/Write Application (Terminal 1)
```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python app.py --mode normal
```
The application will continuously execute read and write transactions, record latency metrics into `HeartbeatLog`, and print the active `default_leader` region (`us-east4`).

### 4. Run Demo Scenario 1: Spanner High Error Rate Alert (Terminal 2)
```bash
./04_trigger_error_rate_scenario.sh 120
```
* Generates non-OK Spanner API requests (`spanner.googleapis.com/api/request_count` with `status != "OK"`).
* Triggers **`[Spanner Observability] High API Error Rate - spanner-obs-mr`** and emails `priteshjani@priteshjani.altostrat.com` and `priteshjani@google.com`.

### 5. Run Demo Scenario 2: Multi-Region Leader Flip / Change Alert (Terminal 2)
```bash
./05_trigger_leader_flip_scenario.sh
```
* Flips `default_leader` from `us-east4` to `us-east1` (or back).
* Terminal 1 (`app.py`) immediately detects and logs:
  `[ALERT - LEADER FLIP DETECTED] Database 'finops-obs-db' default_leader flipped from 'us-east4' ---> 'us-east1'!`
* Triggers **`[Spanner Observability] Multi-Region Leader Flip (Audit & Telemetry)`** and **`[Spanner Observability] Multi-Region Leader Flip (Metric Shift)`** (`spanner.googleapis.com/instance/leader_percentage`), sending email alerts to both notification channels.

### 6. Run Full Validation Check
```bash
./06_validate_all.sh
```
