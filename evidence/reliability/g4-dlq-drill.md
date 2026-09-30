# G4 — DLQ Drill

Owner: Glory (Payments + Integrity)
Date: 2026-09-30

## Requirement

Platform failure drill per the brief: "break the cache or worker,
observe degradation/DLQ, receive an actionable Slack alert, verify
recovery and SLO impact." This closes the DLQ portion specifically —
nothing currently publishes to `devops-g8-payment-events`, so this
proves the redrive policy itself works correctly when a message fails
processing repeatedly.

## Setup

Queue: `devops-g8-payment-events`, redrive policy:
`maxReceiveCount: 5`, target `devops-g8-payment-events-dlq`,
visibility timeout 30s.

## Drill

1. Sent a test message: `{"test":"g4-dlq-drill","payment_id":"drill_001"}`
   (MessageId `da66228e-66d7-414c-9090-0a6c7b95d189`)
2. Received it 5 times, waiting >30s (visibility timeout) between each
   receive without deleting it — simulating a consumer that repeatedly
   fails to process the message:

       ApproximateReceiveCount: 1, 2, 3, 4, 5

3. After the 5th receive's visibility timeout expired, checked both
   queues:

       main queue:  ApproximateNumberOfMessages = 0
       DLQ:         ApproximateNumberOfMessages = 1

4. Retrieved the message from the DLQ directly, confirming the move:

       {
         "MessageId": "da66228e-66d7-414c-9090-0a6c7b95d189",
         "ApproximateReceiveCount": "6",
         "DeadLetterQueueSourceArn": "arn:aws:sqs:eu-west-3:240462142849:devops-g8-payment-events"
       }

Same `MessageId` throughout, `DeadLetterQueueSourceArn` present, and
receive count of 6 (one past the configured max of 5) — this is
definitive proof the redrive policy fired correctly and moved the
message to the DLQ.

## Result

PASS. The SQS -> DLQ mechanism works as configured. This proves the
infrastructure's failure-handling correctly isolates a message that
can't be processed, rather than retrying it forever or silently
dropping it.

## What this does not prove

No real consumer exists for this queue yet — nothing in
`services/payments/` or `services/commission/` currently publishes to
or reads from it. This drill proves the DLQ mechanism itself, not a
real application failure scenario. An actionable Slack alert for
messages landing in the DLQ was not configured or tested as part of
this drill.