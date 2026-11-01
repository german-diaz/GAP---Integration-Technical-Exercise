## Design

The authenticated Apex REST endpoint is `POST /services/apexrest/orders/events`. I chose an authenticated endpoint over a public Site because the sender can use a Salesforce integration user/OAuth client and the signature is then a second authentication/integrity check.

Salesforce stores a small current-state projection: an Account external ID, an Order custom object linked to Account, current status, and the last applied event timestamp/ID. A standard Orders related list on Account shows the result. An Orders Event row keyed by unique `event.id` is the durable idempotency receipt. Redeliveries with the same or older `occurredAt` are duplicates; if the same event ID arrives with a newer `occurredAt`, the receipt and order projection are refreshed to that newer version. Within one batch, the newest valid version of an event ID is selected; ties keep the first occurrence. A distinct event older than the current order timestamp is recorded but not applied. Salesforce is therefore sufficient for the CX status view; no callout to the fictional service is needed per event. Amount, participant, lines and account profile are omitted because this exercise asks for status and the webhook does not carry those fields.

The timestamp comparison assumes `occurredAt` is authoritative and timestamps are comparable for a given order. If the upstream system can emit equal timestamps with distinct transitions, I would ask for a monotonic sequence/version and use that instead. New event IDs are recorded even when stale, which keeps an audit trail and prevents repeated evaluation.

Signature is computed over the original request-body Blob before parsing. The shared secret is stored in an org-level hierarchy custom setting and is not returned in responses. A request body may be one event JSON object or an array of event objects; a single object is normalized to a one-item batch. Each event is validated and processed independently. A malformed event is reported as `rejected` while valid events in the same array are still committed. The response is JSON with an item result for each event index. The endpoint returns 401 for an invalid signature, 400 if one or more items are malformed, 202 when at least one new event is recorded and there are no item validation errors, 200 when all well-formed items are duplicates, and 500 for processing failures. A scalar or invalid JSON body, or an invalid signature, rejects the whole request. Since the sender retries non-2xx responses, a 400 can cause valid items to be delivered again; event-ID receipts make those redeliveries duplicates. The supplied sample secret is only a fixture; replace it in any real deployment and restrict access to the setting.

## Simulate an event against deployed code

The endpoint requires a Salesforce OAuth access token. A standalone script is available at `scripts/simulate_orders_event.py`. It signs the exact bytes it sends, which matters because signature verification is over the raw body. I chose this method over Anonymous Apex because it sends a real HTTP POST to the deployed endpoint, with OAuth authentication and an HMAC signature calculated over the request body. That lets me demonstrate signature validation, and the HTTP response.
Anonymous Apex would be simpler for testing the processor directly, but it bypasses the REST endpoint and signature verification.

powershell:
python .\scripts\simulate_orders_event.py

Alternative Apex script to execute on Anonymous Apex
\scripts\simulate_orders_batch.apex

Apex script to delete all data related to the integration
\scripts\clear_orders_integration_data.apex

The script sends the challenge's full five-event sample sequence in one array. The first run should return HTTP 202; the third item is the repeated `evt_001` and should be marked `duplicate`. The resulting order statuses should be `ord_77d1e9 = Sent` and `ord_52ab10 = Cleared`. Running the script again replays all five events and should return HTTP 200 with duplicate item results.

## Tests

Tests cover single-object and array payloads, duplicate delivery, newer versions of a repeated event ID, stale events, partial acceptance of a mixed batch, invalid root shape, and a correctly signed REST request. No outbound callout is implemented, so there is nothing to mock.

## Questions I would have asked

**Question:** Does Orders send one event per request, a batch, or both?

The sample sequence is an array, so I support both an array and a single event object. I assume the array order is meaningful when two different events for the same order have equal timestamps, and process the valid items in that order.

**Question:** If a batch contains malformed events, should Salesforce reject the entire batch or accept the valid items?

I chose partial acceptance: valid items are committed and malformed items are reported as rejected. Since the sender retries non-2xx deliveries up to three times and suspends the subscription afterward, a partially accepted batch can be resent; event ID receipts make already-accepted items safe to replay.

**Question:** How should duplicate event IDs be handled, especially if the same ID arrives with a different `occurredAt`?

I use the event ID to recognize an event I’ve already received. If it arrives again with the same or an older timestamp, I ignore it as a duplicate. If it arrives with a newer timestamp, I apply the newer version. I assume occurredAt tells me which version is newer.

**Question:** How should distinct events be applied when delivery is out of order?

I compare each event's `occurredAt` with the order's `Last Event At`. A newer or equal event updates the order; an older event is recorded as a receipt but does not move the order backward. Equal timestamps follow payload order because the spec does not provide a sequence number.

**Question:** Should Salesforce keep every event, or only the latest event ID and timestamp on the order?

I keep one receipt per unique event and do not delete them, which keeps deduplication and troubleshooting simple. In production, I would agree on a retention period based on the sender’s retry and replay window and our audit needs. A scheduled Batch Apex job could archive or delete older receipts while Order__c keeps the current status and latest event timestamp. This limits Salesforce storage while preserving receipts for the period when replays are expected.

**Question:** Should Salesforce create Accounts, and what field identifies an existing Account from Orders?

I assume Accounts already exist and are matched by `Orders Account ID`. The webhook does not include enough account details to create or safely match an Account automatically.

## Deliberately left out

- Account/order detail synchronization, amount and line-item persistence, outbound reads, and a live Orders Named Credential. the requested view is status-focused.
- Queueable processing, retry queue, replay endpoint, monitoring dashboard, and receipt cleanup: the exercise's event volume and 10-second sender timeout fit a small synchronous transaction.
- Automated Account creation and data reconciliation: there is not enough source data in the event to do this safely.
