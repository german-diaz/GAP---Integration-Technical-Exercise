/** Tests event parsing, deduplication, ordering, persistence, and REST authentication. */
@IsTest
private class OrdersEventProcessorTest {
    private static String payload(
        String id,
        String status,
        String occurredAtValue,
        String orderId
    ) {
        return '{"subscriptionId":"sub_test","event":{"id":"' + id +
            '","type":"order.' + status + '","occurredAt":"' + occurredAtValue +
            '","version":"1.0"},"data":{"orderId":"' + orderId +
            '","orderFriendlyId":"friendly-' + orderId +
            '","accountId":"acct-test","accountFriendlyId":"acct-friendly"}}';
    }

    @IsTest
    static void processesValidItemsAndReportsDuplicatesAndStaleEvents() {
        insert new Account(
            Name='Test account',
            Orders_Account_Id__c='acct-test'
        );
        String body = '[' +
            payload(
                'evt-2',
                'sent',
                '2026-10-12T14:03:11Z',
                'ord-test'
            ) + ',' +
            payload(
                'evt-2',
                'sent',
                '2026-10-12T14:03:11Z',
                'ord-test'
            ) + ',' +
            payload(
                'evt-1',
                'inProgress',
                '2026-10-10T10:00:00Z',
                'ord-test'
            ) +
            ']';

        Test.startTest();
        OrdersEventProcessor.Result first = OrdersEventProcessor.processBatch(
            body
        );
        OrdersEventProcessor.Result retry = OrdersEventProcessor.processBatch(
            body
        );
        Test.stopTest();

        Order__c orderRecord = [
            SELECT Status__c, Last_Event_Id__c
            FROM Order__c
            WHERE Orders_Order_Id__c = 'ord-test'
        ];
        System.assertEquals(3, first.items.size());
        System.assertEquals('accepted', first.items[0].status);
        System.assertEquals('duplicate', first.items[1].status);
        System.assertEquals('stale', first.items[2].status);
        System.assertEquals(true, first.hasNewEvents);
        System.assertEquals('duplicate', retry.items[0].status);
        System.assertEquals('duplicate', retry.items[1].status);
        System.assertEquals('duplicate', retry.items[2].status);
        System.assertEquals('Sent', orderRecord.Status__c);
        System.assertEquals('evt-2', orderRecord.Last_Event_Id__c);
        System.assertEquals(
            2,
            [SELECT count() FROM Orders_Event__c]
        );
    }

    @IsTest
    static void acceptsValidItemsAndRejectsMalformedItemsInSameBatch() {
        insert new Account(
            Name='Partial batch account',
            Orders_Account_Id__c='acct-test'
        );
        String malformed = '{"event":{"id":"evt-bad","type":"order.created"},"data":{}}';
        String body = '[' +
            payload(
                'evt-good',
                'sent',
                '2026-10-12T14:03:11Z',
                'ord-good'
            ) + ',' +
            malformed +
            ']';

        OrdersEventProcessor.Result result = OrdersEventProcessor.processBatch(
            body
        );

        System.assertEquals(2, result.items.size());
        System.assertEquals('accepted', result.items[0].status);
        System.assertEquals('rejected', result.items[1].status);
        System.assertEquals('missing_required_fields', result.items[1].errorCode);
        System.assertEquals(true, result.hasValidationErrors);
        System.assertEquals(
            1,
            [SELECT count() FROM Order__c WHERE Orders_Order_Id__c = 'ord-good']
        );
        System.assertEquals(
            1,
            [SELECT count() FROM Orders_Event__c]
        );
    }

    @IsTest
    static void acceptsSingleEventObject() {
        insert new Account(
            Name='Single event account',
            Orders_Account_Id__c='acct-test'
        );

        OrdersEventProcessor.Result result = OrdersEventProcessor.processBatch(
            payload(
                'evt-single',
                'sent',
                '2026-10-12T14:03:11Z',
                'ord-single'
            )
        );

        System.assertEquals(1, result.items.size());
        System.assertEquals('accepted', result.items[0].status);
        System.assertEquals('evt-single', result.items[0].eventId);
    }

    @IsTest
    static void keepsNewestVersionOfRepeatedEventId() {
        insert new Account(
            Name='Repeated event account',
            Orders_Account_Id__c='acct-test'
        );
        String olderVersion = payload(
            'evt-changing',
            'inProgress',
            '2026-10-09T10:00:00Z',
            'ord-changing'
        );
        String newerVersion = payload(
            'evt-changing',
            'sent',
            '2026-10-10T10:00:00Z',
            'ord-changing'
        );

        OrdersEventProcessor.Result initialResult = OrdersEventProcessor.processBatch(
            olderVersion
        );
        OrdersEventProcessor.Result batchResult = OrdersEventProcessor.processBatch(
            '[' + olderVersion + ',' + newerVersion + ']'
        );
        OrdersEventProcessor.Result redeliveryResult = OrdersEventProcessor.processBatch(
            newerVersion
        );

        Order__c orderRecord = [
            SELECT Status__c, Last_Event_Id__c
            FROM Order__c
            WHERE Orders_Order_Id__c = 'ord-changing'
        ];
        Orders_Event__c receipt = [
            SELECT Event_Type__c, Occurred_At__c
            FROM Orders_Event__c
            WHERE Event_Id__c = 'evt-changing'
        ];

        System.assertEquals('accepted', initialResult.items[0].status);
        System.assertEquals('duplicate', batchResult.items[0].status);
        System.assertEquals('accepted', batchResult.items[1].status);
        System.assertEquals('duplicate', redeliveryResult.items[0].status);
        System.assertEquals('Sent', orderRecord.Status__c);
        System.assertEquals('evt-changing', orderRecord.Last_Event_Id__c);
        System.assertEquals('order.sent', receipt.Event_Type__c);
        System.assertEquals(
            Datetime.newInstanceGmt(2026, 10, 10, 10, 0, 0),
            receipt.Occurred_At__c
        );
    }

    @IsTest
    static void rejectsNonObjectAndNonArrayBody() {
        try {
            OrdersEventProcessor.processBatch(
                '"not an event"'
            );
            System.assert(
                false,
                'Expected InvalidBatchException'
            );
        } catch (OrdersEventProcessor.InvalidBatchException expected) {
            System.assertEquals(0, [SELECT count() FROM Orders_Event__c]);
        }
    }

    @IsTest
    static void endpointAuthenticatesRawBatchBody() {
        insert new Account(
            Name='Endpoint account',
            Orders_Account_Id__c='acct-test'
        );
        Orders_Integration_Settings__c settings = new Orders_Integration_Settings__c(
            SetupOwnerId=UserInfo.getOrganizationId(),
            Shared_Secret__c='test-secret'
        );
        insert settings;
        String body = payload(
            'evt-rest',
            'sent',
            '2026-10-12T14:03:11Z',
            'ord-rest'
        );
        RestRequest req = new RestRequest();
        req.requestUri='/services/apexrest/orders/events';
        req.httpMethod='POST';
        req.requestBody=Blob.valueOf(body);
        req.addHeader(
            'Orders-Signature',
            EncodingUtil.convertToHex(
                Crypto.generateMac(
                    'HmacSHA256',
                    Blob.valueOf(body),
                    Blob.valueOf('test-secret')
                )
            )
        );
        RestContext.request=req;
        RestContext.response=new RestResponse();

        Test.startTest();
        OrdersEventRest.receive();
        Test.stopTest();

        System.assertEquals(
            202,
            RestContext.response.statusCode
        );
    }
}
