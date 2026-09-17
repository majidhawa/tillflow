import json
import os
import urllib.request

import boto3

secrets_client = boto3.client("secretsmanager")

# The Slack alert contract (capstone brief): every alert should carry
# environment, service, symptom, user/SLO impact, observed value, Grafana
# panel, runbook link, owner, and first safe action. CloudWatch alarms
# don't have native fields for most of these, so alarms are expected to
# JSON-encode them into AlarmDescription; anything not supplied that way
# falls back to raw alarm fields so an alarm without a contract
# description still produces a usable (if less complete) message.
CONTRACT_FIELDS = [
    "environment",
    "service",
    "symptom",
    "user_impact",
    "observed_value",
    "grafana_panel",
    "runbook_link",
    "owner",
    "first_safe_action",
]


def _get_webhook_url():
    secret_arn = os.environ["SLACK_WEBHOOK_SECRET_ARN"]
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    return response["SecretString"]


def _contract_fields_from_alarm(alarm):
    fields = {}
    description = alarm.get("AlarmDescription") or ""
    try:
        parsed = json.loads(description)
        if isinstance(parsed, dict):
            fields = {k: parsed.get(k) for k in CONTRACT_FIELDS}
    except (json.JSONDecodeError, TypeError):
        pass

    fields.setdefault("environment", os.environ.get("ENVIRONMENT_NAME", "unknown"))
    fields.setdefault("service", (alarm.get("Trigger") or {}).get("Namespace"))
    fields.setdefault("symptom", alarm.get("AlarmName"))
    fields.setdefault("user_impact", None)
    fields.setdefault("observed_value", alarm.get("NewStateReason", "n/a"))
    fields.setdefault("grafana_panel", None)
    fields.setdefault("runbook_link", None)
    fields.setdefault("owner", None)
    fields.setdefault("first_safe_action", None)
    return fields


def _format_message(alarm):
    state = alarm.get("NewStateValue", "UNKNOWN")
    emoji = {"ALARM": ":rotating_light:", "OK": ":white_check_mark:"}.get(
        state, ":grey_question:"
    )
    fields = _contract_fields_from_alarm(alarm)

    lines = [f"{emoji} *{state}* — {fields['symptom']}"]
    lines.append(
        f"*Environment:* {fields['environment']}   *Service:* {fields['service']}"
    )
    if fields["user_impact"]:
        lines.append(f"*User/SLO impact:* {fields['user_impact']}")
    lines.append(f"*Observed value:* {fields['observed_value']}")
    if fields["grafana_panel"]:
        lines.append(f"*Grafana panel:* {fields['grafana_panel']}")
    if fields["runbook_link"]:
        lines.append(f"*Runbook:* {fields['runbook_link']}")
    if fields["owner"]:
        lines.append(f"*Owner:* {fields['owner']}")
    if fields["first_safe_action"]:
        lines.append(f"*First safe action:* {fields['first_safe_action']}")

    return "\n".join(lines)


def lambda_handler(event, _context):
    webhook_url = _get_webhook_url()

    for record in event.get("Records", []):
        message_raw = record["Sns"]["Message"]
        try:
            alarm = json.loads(message_raw)
        except json.JSONDecodeError:
            alarm = {
                "AlarmName": message_raw,
                "NewStateValue": "ALARM",
                "NewStateReason": "",
            }

        payload = json.dumps({"text": _format_message(alarm)}).encode("utf-8")
        request = urllib.request.Request(
            webhook_url,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(request, timeout=5)

    return {"statusCode": 200}
