#!/usr/bin/env bash
# ==============================================================================
# Step 3: Setup Cloud Monitoring Notification Channels, Alert Policies & Dashboard
#   Scenario 1: Spanner High Error Rate Alert -> Emails Notification Channels
#   Scenario 2: Multi-Region Spanner Leader Flip / Change Alert -> Emails Notification Channels
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
mkdir -p "${SCRIPT_DIR}/alerts"

echo "=================================================================="
echo "1. Creating Email Notification Channels in Project '${PROJECT_ID}'"
echo "   Emails: ${NOTIFICATION_EMAIL_1}, ${NOTIFICATION_EMAIL_2}"
echo "=================================================================="

ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)"

create_or_get_email_channel() {
  local email="$1"
  local display_name="$2"
  local existing

  existing=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/notificationChannels" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ch in data.get('notificationChannels', []):
    if ch.get('type') == 'email' and ch.get('labels', {}).get('email_address') == '${email}':
        print(ch['name'])
        break
" || true)

  if [[ -n "${existing}" ]]; then
    echo "${existing}"
  else
    curl -s -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"type\": \"email\",
        \"displayName\": \"${display_name}\",
        \"labels\": {
          \"email_address\": \"${email}\"
        },
        \"enabled\": true
      }" \
      "https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}/notificationChannels" \
      | python3 -c "import sys, json; print(json.load(sys.stdin)['name'])"
  fi
}

CHANNEL_1=$(create_or_get_email_channel "${NOTIFICATION_EMAIL_1}" "Pritesh Jani (Altostrat)")
CHANNEL_2=$(create_or_get_email_channel "${NOTIFICATION_EMAIL_2}" "Pritesh Jani (Google)")

echo "   -> Channel 1 (${NOTIFICATION_EMAIL_1}): ${CHANNEL_1}"
echo "   -> Channel 2 (${NOTIFICATION_EMAIL_2}): ${CHANNEL_2}"

echo ""
echo "=================================================================="
echo "2. Creating Log-Based Metric for Spanner Multi-Region Leader Flip"
echo "=================================================================="
if gcloud logging metrics describe spanner_leader_change_events --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[OK] Log-based metric 'spanner_leader_change_events' already exists."
else
  gcloud logging metrics create spanner_leader_change_events \
    --project="${PROJECT_ID}" \
    --description="Counts Spanner multi-region leader flips (default_leader DDL changes and instance config updates)" \
    --log-filter="resource.type=\"spanner_instance\" AND resource.labels.instance_id=\"${INSTANCE_ID}\" AND (protoPayload.methodName=\"google.spanner.admin.database.v1.DatabaseAdmin.UpdateDatabaseDdl\" OR protoPayload.methodName=\"google.spanner.admin.instance.v1.InstanceAdmin.UpdateInstance\")"
  echo "[SUCCESS] Created log-based metric 'spanner_leader_change_events'."
fi

echo ""
echo "=================================================================="
echo "3. Creating Alert Policy 1: Spanner High API Error Rate Alert"
echo "=================================================================="
cat > "${SCRIPT_DIR}/alerts/alert_error_rate.json" <<EOF
{
  "displayName": "[Spanner Observability] High API Error Rate - ${INSTANCE_ID}",
  "documentation": {
    "content": "### Spanner Instance Error Rate Alert\n\nSpanner instance **${INSTANCE_ID}** in project **${PROJECT_ID}** (VPC: **${VPC_NETWORK}**) is returning non-OK API responses (status != OK).\n\n- **Instance**: ${INSTANCE_ID}\n- **Database**: ${DATABASE_ID}\n- **Action**: Check Cloud Monitoring dashboard and application error logs for DEADLINE_EXCEEDED, ABORTED, INVALID_ARGUMENT, or UNAVAILABLE errors.",
    "mimeType": "text/markdown"
  },
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "${CHANNEL_1}",
    "${CHANNEL_2}"
  ],
  "conditions": [
    {
      "displayName": "Spanner Non-OK API Request Rate > 0.05 req/s",
      "conditionThreshold": {
        "filter": "resource.type = \"spanner_instance\" AND resource.labels.instance_id = \"${INSTANCE_ID}\" AND metric.type = \"spanner.googleapis.com/api/api_request_count\" AND metric.labels.status != \"OK\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE",
            "crossSeriesReducer": "REDUCE_SUM",
            "groupByFields": [
              "resource.label.instance_id",
              "metric.label.status"
            ]
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0.05,
        "duration": "60s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "1800s"
  }
}
EOF

EXISTING_ERR_POLICY=$(gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName='[Spanner Observability] High API Error Rate - ${INSTANCE_ID}'" \
  --format="value(name)" 2>/dev/null | head -n 1 || true)

if [[ -n "${EXISTING_ERR_POLICY}" ]]; then
  gcloud monitoring policies update "${EXISTING_ERR_POLICY}" \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_error_rate.json"
  echo "[OK] Updated existing Error Rate Alert Policy: ${EXISTING_ERR_POLICY}"
else
  gcloud monitoring policies create \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_error_rate.json"
  echo "[SUCCESS] Created Error Rate Alert Policy."
fi

echo ""
echo "=================================================================="
echo "4. Creating Alert Policy 2A: Multi-Region Leader Percentage Shift Alert"
echo "   Monitors spanner.googleapis.com/instance/leader_percentage_by_region in ${PRIMARY_LEADER_REGION}"
echo "=================================================================="
cat > "${SCRIPT_DIR}/alerts/alert_leader_percentage_shift.json" <<EOF
{
  "displayName": "[Spanner Observability] Multi-Region Leader Flip (Metric Shift) - ${INSTANCE_ID}",
  "documentation": {
    "content": "### Multi-Region Spanner Leader Shift Detected\n\nThe primary leader region **${PRIMARY_LEADER_REGION}** for multi-region Spanner instance **${INSTANCE_ID}** (**${INSTANCE_CONFIG}**) experienced a drop in leader_percentage_by_region below 50%, indicating that read-write leader tablets have flipped/failed over to another region (e.g. **${ALTERNATE_LEADER_REGION}**).\n\n- **Project**: ${PROJECT_ID}\n- **Instance**: ${INSTANCE_ID}\n- **Expected Primary Leader**: ${PRIMARY_LEADER_REGION}",
    "mimeType": "text/markdown"
  },
  "userLabels": {},
  "conditions": [
    {
      "displayName": "Primary Leader Region (${PRIMARY_LEADER_REGION}) Leader Percentage < 50%",
      "conditionThreshold": {
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "crossSeriesReducer": "REDUCE_MEAN",
            "groupByFields": [
              "resource.label.instance_id",
              "metric.label.region"
            ],
            "perSeriesAligner": "ALIGN_MEAN"
          }
        ],
        "comparison": "COMPARISON_LT",
        "duration": "60s",
        "filter": "resource.type = \"spanner_instance\" AND resource.labels.instance_id = \"${INSTANCE_ID}\" AND metric.type = \"spanner.googleapis.com/instance/leader_percentage_by_region\" AND metric.labels.region = \"${PRIMARY_LEADER_REGION}\"",
        "thresholdValue": 0.9,
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "1800s"
  },
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "${CHANNEL_1}",
    "${CHANNEL_2}"
  ]
}
EOF

EXISTING_LEADER_METRIC_POLICY=$(gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName='[Spanner Observability] Multi-Region Leader Flip (Metric Shift) - ${INSTANCE_ID}'" \
  --format="value(name)" 2>/dev/null | head -n 1 || true)

if [[ -n "${EXISTING_LEADER_METRIC_POLICY}" ]]; then
  gcloud monitoring policies update "${EXISTING_LEADER_METRIC_POLICY}" \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_leader_percentage_shift.json"
  echo "[OK] Updated existing Multi-Region Leader Percentage Shift Alert Policy: ${EXISTING_LEADER_METRIC_POLICY}"
else
  gcloud monitoring policies create \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_leader_percentage_shift.json"
  echo "[SUCCESS] Created Multi-Region Leader Percentage Shift Alert Policy."
fi

echo ""
echo "=================================================================="
echo "5. Creating Alert Policy 2B: Multi-Region Leader Config Flip (Audit Log Alert)"
echo "   Fires immediately when default_leader changes or leader flip event occurs"
echo "=================================================================="
cat > "${SCRIPT_DIR}/alerts/alert_leader_config_flip.json" <<EOF
{
  "displayName": "[Spanner Observability] Multi-Region Leader Flip (Audit & Telemetry) - ${INSTANCE_ID}",
  "documentation": {
    "content": "### Multi-Region Spanner Leader Flip / Change Alert\n\nA multi-region leader flip (default_leader modification or leader election change) was detected on Spanner instance **${INSTANCE_ID}** / database **${DATABASE_ID}** in project **${PROJECT_ID}**.\n\n- **VPC**: ${VPC_NETWORK}\n- **Primary Region**: ${PRIMARY_LEADER_REGION}\n- **Alternate Region**: ${ALTERNATE_LEADER_REGION}",
    "mimeType": "text/markdown"
  },
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "${CHANNEL_1}",
    "${CHANNEL_2}"
  ],
  "conditions": [
    {
      "displayName": "Spanner Leader Change Event Count > 0",
      "conditionThreshold": {
        "filter": "resource.type = \"spanner_instance\" AND metric.type = \"logging.googleapis.com/user/spanner_leader_change_events\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_SUM",
            "crossSeriesReducer": "REDUCE_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "1800s"
  }
}
EOF

EXISTING_LEADER_LOG_POLICY=$(gcloud monitoring policies list \
  --project="${PROJECT_ID}" \
  --filter="displayName='[Spanner Observability] Multi-Region Leader Flip (Audit & Telemetry) - ${INSTANCE_ID}'" \
  --format="value(name)" 2>/dev/null | head -n 1 || true)

if [[ -n "${EXISTING_LEADER_LOG_POLICY}" ]]; then
  gcloud monitoring policies update "${EXISTING_LEADER_LOG_POLICY}" \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_leader_config_flip.json"
  echo "[OK] Updated existing Multi-Region Leader Config Flip Alert Policy: ${EXISTING_LEADER_LOG_POLICY}"
else
  gcloud monitoring policies create \
    --project="${PROJECT_ID}" \
    --policy-from-file="${SCRIPT_DIR}/alerts/alert_leader_config_flip.json"
  echo "[SUCCESS] Created Multi-Region Leader Config Flip Alert Policy."
fi

echo ""
echo "=================================================================="
echo "6. Creating Cloud Monitoring Spanner Observability Dashboard"
echo "=================================================================="
cat > "${SCRIPT_DIR}/alerts/dashboard_spanner_observability.json" <<EOF
{
  "displayName": "Spanner Multi-Region Availability & Observability (${INSTANCE_ID})",
  "gridLayout": {
    "columns": "2",
    "widgets": [
      {
        "title": "Spanner API Request Rate by Status (OK vs Errors)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"spanner_instance\" AND resource.label.\"instance_id\"=\"${INSTANCE_ID}\" AND metric.type=\"spanner.googleapis.com/api/api_request_count\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_RATE",
                    "crossSeriesReducer": "REDUCE_SUM",
                    "groupByFields": ["metric.label.\"status\""]
                  }
                }
              },
              "plotType": "LINE"
            }
          ]
        }
      },
      {
        "title": "Multi-Region Leader Percentage by Region (Leader Flip Tracking)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"spanner_instance\" AND resource.label.\"instance_id\"=\"${INSTANCE_ID}\" AND metric.type=\"spanner.googleapis.com/instance/leader_percentage_by_region\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN",
                    "crossSeriesReducer": "REDUCE_MEAN",
                    "groupByFields": ["metric.label.\"region\""]
                  }
                }
              },
              "plotType": "STACKED_AREA"
            }
          ]
        }
      },
      {
        "title": "Spanner API Request Latency (P99 by Method)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"spanner_instance\" AND resource.label.\"instance_id\"=\"${INSTANCE_ID}\" AND metric.type=\"spanner.googleapis.com/api/request_latencies\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_PERCENTILE_99",
                    "crossSeriesReducer": "REDUCE_MEAN",
                    "groupByFields": ["metric.label.\"method\""]
                  }
                }
              },
              "plotType": "LINE"
            }
          ]
        }
      },
      {
        "title": "Spanner High-Priority CPU Utilization (%)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"spanner_instance\" AND resource.label.\"instance_id\"=\"${INSTANCE_ID}\" AND metric.type=\"spanner.googleapis.com/instance/cpu/utilization_by_priority\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN",
                    "crossSeriesReducer": "REDUCE_SUM",
                    "groupByFields": ["metric.label.\"priority\""]
                  }
                }
              },
              "plotType": "LINE"
            }
          ]
        }
      }
    ]
  }
}
EOF

gcloud monitoring dashboards create \
  --project="${PROJECT_ID}" \
  --config-from-file="${SCRIPT_DIR}/alerts/dashboard_spanner_observability.json" || true

echo "[SUCCESS] Observability Notification Channels, Alerts, and Dashboard configured."
