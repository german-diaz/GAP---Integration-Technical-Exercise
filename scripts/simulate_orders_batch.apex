// Apex script to simulate a batch of Orders events for testing the REST endpoint. This script constructs a fake request with a valid HMAC signature,
// but does not make a real HTTP request or test OAuth.
// execute on Anonymous Apex
String subscriptionId = 'sub_a1b2c3d4e5f67890abcdef12';
String accountId = 'acct_8f3c2a';
String accountFriendlyId = 'AC-260914-017-2231';
String orderOneId = 'ord_77d1e9';
String orderOneFriendlyId = 'OR-261001-017-2231';
String orderTwoId = 'ord_52ab10';
String orderTwoFriendlyId = 'OR-260922-017-1187';

List<Object> events = new List<Object>();

events.add(new Map<String, Object>{
    'subscriptionId' => subscriptionId,
    'event' => new Map<String, Object>{
        'id' => 'evt_001',
        'type' => 'order.inProgress',
        'occurredAt' => '2026-10-10T10:00:00Z',
        'version' => '1.0'
    },
    'data' => new Map<String, Object>{
        'orderId' => orderOneId,
        'orderFriendlyId' => orderOneFriendlyId,
        'accountId' => accountId,
        'accountFriendlyId' => accountFriendlyId
    }
});

events.add(new Map<String, Object>{
    'subscriptionId' => subscriptionId,
    'event' => new Map<String, Object>{
        'id' => 'evt_002',
        'type' => 'order.waitingForParticipant',
        'occurredAt' => '2026-10-11T10:00:00Z',
        'version' => '1.0'
    },
    'data' => new Map<String, Object>{
        'orderId' => orderOneId,
        'orderFriendlyId' => orderOneFriendlyId,
        'accountId' => accountId,
        'accountFriendlyId' => accountFriendlyId
    }
});

events.add(new Map<String, Object>{
    'subscriptionId' => subscriptionId,
    'event' => new Map<String, Object>{
        'id' => 'evt_001',
        'type' => 'order.inProgress',
        'occurredAt' => '2026-10-10T10:00:00Z',
        'version' => '1.0'
    },
    'data' => new Map<String, Object>{
        'orderId' => orderOneId,
        'orderFriendlyId' => orderOneFriendlyId,
        'accountId' => accountId,
        'accountFriendlyId' => accountFriendlyId
    }
});

events.add(new Map<String, Object>{
    'subscriptionId' => subscriptionId,
    'event' => new Map<String, Object>{
        'id' => 'evt_004',
        'type' => 'order.sent',
        'occurredAt' => '2026-10-12T14:03:11Z',
        'version' => '1.0'
    },
    'data' => new Map<String, Object>{
        'orderId' => orderOneId,
        'orderFriendlyId' => orderOneFriendlyId,
        'accountId' => accountId,
        'accountFriendlyId' => accountFriendlyId
    }
});

events.add(new Map<String, Object>{
    'subscriptionId' => subscriptionId,
    'event' => new Map<String, Object>{
        'id' => 'evt_003',
        'type' => 'order.cleared',
        'occurredAt' => '2026-10-09T09:41:27Z',
        'version' => '1.0'
    },
    'data' => new Map<String, Object>{
        'orderId' => orderTwoId,
        'orderFriendlyId' => orderTwoFriendlyId,
        'accountId' => accountId,
        'accountFriendlyId' => accountFriendlyId
    }
});

String body = JSON.serialize(events);
String secret = OrdersIntegrationConfig.getSecret();
System.assert(
    !String.isBlank(secret),
    'Configure the Orders Integration Settings shared secret first.'
);

String signature = EncodingUtil.convertToHex(
    Crypto.generateMac(
        'HmacSHA256',
        Blob.valueOf(body),
        Blob.valueOf(secret)
    )
);

RestRequest request = new RestRequest();
request.requestUri = '/services/apexrest/orders/events';
request.httpMethod = 'POST';
request.requestBody = Blob.valueOf(body);
request.addHeader('Orders-Signature', signature);

RestContext.request = request;
RestContext.response = new RestResponse();
OrdersEventRest.receive();

System.debug(LoggingLevel.ERROR, 'HTTP status: ' + RestContext.response.statusCode);
System.debug(
    LoggingLevel.ERROR,
    'Response: ' + RestContext.response.responseBody.toString()
);
