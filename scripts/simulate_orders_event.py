#!/usr/bin/env python3
"""Send the sample Orders event to the Salesforce Apex REST endpoint.

The payload is the challenge's five-event sample sequence, including an
in-batch duplicate and an out-of-order event for the second order.
"""

import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request


EVENTS = [
    {
        "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12",
        "event": {
            "id": "evt_001",
            "type": "order.inProgress",
            "occurredAt": "2026-10-10T10:00:00Z",
            "version": "1.0",
        },
        "data": {
            "orderId": "ord_77d1e9",
            "orderFriendlyId": "OR-261001-017-2231",
            "accountId": "acct_8f3c2a",
            "accountFriendlyId": "AC-260914-017-2231",
        },
    },
    {
        "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12",
        "event": {
            "id": "evt_002",
            "type": "order.waitingForParticipant",
            "occurredAt": "2026-10-11T10:00:00Z",
            "version": "1.0",
        },
        "data": {
            "orderId": "ord_77d1e9",
            "orderFriendlyId": "OR-261001-017-2231",
            "accountId": "acct_8f3c2a",
            "accountFriendlyId": "AC-260914-017-2231",
        },
    },
    {
        "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12",
        "event": {
            "id": "evt_001",
            "type": "order.inProgress",
            "occurredAt": "2026-10-10T10:00:00Z",
            "version": "1.0",
        },
        "data": {
            "orderId": "ord_77d1e9",
            "orderFriendlyId": "OR-261001-017-2231",
            "accountId": "acct_8f3c2a",
            "accountFriendlyId": "AC-260914-017-2231",
        },
    },
    {
        "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12",
        "event": {
            "id": "evt_004",
            "type": "order.sent",
            "occurredAt": "2026-10-12T14:03:11Z",
            "version": "1.0",
        },
        "data": {
            "orderId": "ord_77d1e9",
            "orderFriendlyId": "OR-261001-017-2231",
            "accountId": "acct_8f3c2a",
            "accountFriendlyId": "AC-260914-017-2231",
        },
    },
    {
        "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12",
        "event": {
            "id": "evt_003",
            "type": "order.cleared",
            "occurredAt": "2026-10-09T09:41:27Z",
            "version": "1.0",
        },
        "data": {
            "orderId": "ord_52ab10",
            "orderFriendlyId": "OR-260922-017-1187",
            "accountId": "acct_8f3c2a",
            "accountFriendlyId": "AC-260914-017-2231",
        },
    },
]


def main() -> int:
    instance_url = os.environ.get("SF_INSTANCE_URL", "").rstrip("/")
    access_token = os.environ.get("SF_ACCESS_TOKEN", "")
    shared_secret = os.environ.get("ORDERS_SHARED_SECRET", "")

    if not instance_url or not access_token or not shared_secret:
        print(
            "Set SF_INSTANCE_URL, SF_ACCESS_TOKEN, and ORDERS_SHARED_SECRET "
            "in your environment before running this script.",
            file=sys.stderr,
        )
        return 2

    # These exact bytes are both signed and sent. Do not reformat the body
    # after calculating the signature; Apex verifies the raw request body.
    body = json.dumps(EVENTS, separators=(",", ":")).encode("utf-8")
    signature = hmac.new(
        shared_secret.encode("utf-8"), body, hashlib.sha256
    ).hexdigest()

    request = urllib.request.Request(
        f"{instance_url}/services/apexrest/orders/events",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Orders-Signature": signature,
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response_body = response.read().decode("utf-8", errors="replace")
            print(f"HTTP {response.status}")
            print(response_body)
            return 0 if 200 <= response.status < 300 else 1
    except urllib.error.HTTPError as error:
        response_body = error.read().decode("utf-8", errors="replace")
        print(f"HTTP {error.code}", file=sys.stderr)
        print(response_body, file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"Request failed: {error.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
