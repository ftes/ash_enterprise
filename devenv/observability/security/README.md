# Security and audit alert rules for SigNoz

This application's own SigNoz alert rules, for the same signals as the `security_alerts` recipe pack (`priv/packs/security_alerts/`), and for the audit trail's own health. Provision them beside the module's own with the `observability.provision` option:

```nix
observability.provision = [ "${ash_enterprise}/devenv/observability/security" ];
```

The security rules read the audit chain itself: committed audit events reach SigNoz as OTLP log records (`AshEnterprise.Audit.ExportWorker`, every minute, each chain from its own cursor), so a rule counts what the tamper-evident log recorded rather than spans, which are sampled and say nothing about a rolled-back write. A record carries only the allowlisted structural fields of `AshEnterprise.Audit.OtlpExport` (`audit.resource`, `audit.action`, `audit.actor_id`, `audit.tenant_id`, `audit.sequence`, `audit.hash` and the rest), never a record id or any value of what was written.

| Rule | Signal | Fires when | Severity |
|---|---|---|---|
| Refused sign-ins above 20 in 5 minutes | logs | more than 20 `AuthenticationEvent` records with `audit.authentication.outcome = 'refused'` at the `password` or `oidc` door in five minutes | warning |
| A role was assigned | logs | any `UserRole` `assign` or `assign_governed` record | info |
| An API key was issued | logs | any `ApiKey` `issue` record | info |
| A break-glass session was approved | logs | any `BreakGlassSession` `approve` record | warning |
| Audit export 15 minutes behind | metrics | `ash_enterprise.audit.export.lag_seconds` above 900 | warning |
| Retention left events past the hot window | metrics | `ash_enterprise.audit.retention.backlog` above 0 | info |
| An archive move did not verify | metrics | `ash_enterprise.audit.retention.failed` above 0 | warning |

The security rules carry `category: security`; the three audit rules carry `category: audit`, so the pack's inbound recipe does not open a review for them.

They count across the whole deployment, not per tenant: SigNoz holds no tenant boundary, so these are the deployment operator's alarms. A tenant's own alarms are the pack's recipes, which open a review in that tenant (`docs/QUESTIONS.md`, q38).

Refused sign-ins are written in the chain with no tenant, including those for addresses that belong to no account, which no tenant records. That chain has no commit-order guarantee, so its export is best effort: it is read only up to events older than a settle window (60 seconds), and a sign-in whose transaction stays open longer than that can be missed. The other security rules read tenant chains, which are exported in commit order and skip nothing.

Delivery is at least once. A batch the endpoint acknowledged whose cursor update then failed is sent again, so a rule can count an event twice in that case; `(audit.tenant_id, audit.sequence, audit.hash)` names one event exactly. The export runs only where `OTEL_EXPORTER_OTLP_ENDPOINT` is set (`config/runtime.exs`), and the metric rules need the same setting, which also turns on the OTLP metrics reader. A run that cannot post leaves its cursor where it was, records why on the cursor (`AshEnterprise.Audit.ExportCursor.last_error`) and is retried by the next run; the export-lag rule is what tells someone.

Like the module's own rules they route through SigNoz's notification policies and notify nobody until a channel and a policy are set up. A webhook channel pointed at this application's alert webhook (`POST /webhooks/alerts-signoz`, `AshEnterprise.Automation.AlertWebhook`) records each firing alert as an `alert.firing` occurrence in the organization its key maps to, where the pack's `security_alerts.inbound_security_alert` recipe opens a review. SigNoz does not sign webhook bodies, so the channel delivers through a relay that holds the key and adds the `x-alert-key`, `x-alert-timestamp` and `x-alert-signature` headers.

`test/ash_enterprise/observability/security_rules_test.exs` checks that every attribute and value a log rule filters on is one the exporter emits, and every metric a metric rule reads is one the application exports. It does not run SigNoz.
