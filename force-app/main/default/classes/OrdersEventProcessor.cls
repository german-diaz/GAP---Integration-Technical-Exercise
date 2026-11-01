// Validates incoming Orders events and updates Salesforce Order__c records and Orders_Event__c receipts.
public without sharing class OrdersEventProcessor {
    // Identifies a malformed batch body or unsupported JSON type.
    public class InvalidBatchException extends Exception {}
    // Identifies an event that is malformed or fails field validation.
    public class InvalidEventException extends Exception {}
    // Identifies a database failure that prevents safe batch completion.
    public class BatchProcessingException extends Exception {}

    private static final Map<String, String> STATUS_BY_TYPE = new Map<String, String>{
        'order.inProgress' => 'In Progress',
        'order.waitingForParticipant' => 'Waiting for Participant',
        'order.sent' => 'Sent',
        'order.cleared' => 'Cleared',
        'order.returned' => 'Returned'
    };

    // Parses one event or a batch, deduplicates event IDs, and applies current events.
    public static Result processBatch(
        String jsonBody
    ) {
        Object parsedBody;
        try {
            parsedBody = JSON.deserializeUntyped(jsonBody);
        } catch (Exception e) {
            throw new InvalidBatchException('Expected a JSON object or array');
        }

        List<Object> rawEvents = new List<Object>();
        if (parsedBody instanceof List<Object>) {
            rawEvents = (List<Object>) parsedBody;
        } else if (parsedBody instanceof Map<String, Object>) {
            rawEvents.add(parsedBody);
        } else {
            throw new InvalidBatchException('Expected a JSON object or array');
        }

        if (rawEvents.isEmpty()) {
            throw new InvalidBatchException('Batch must contain at least one event');
        }

        Result result = new Result();
        List<EventProcessingItem> selectedEvents = new List<EventProcessingItem>();
        Map<String, List<EventProcessingItem>> eventsById = new Map<String, List<EventProcessingItem>>();
        Map<String, EventProcessingItem> selectedEventById = new Map<String, EventProcessingItem>();
        Map<String, Integer> selectedEventPositionById = new Map<String, Integer>();

        for (Integer i = 0; i < rawEvents.size(); i++) {
            ItemResult item = new ItemResult();
            item.index = i;
            item.status = 'rejected';
            result.items.add(item);

            EventProcessingItem eventItem;
            String validationCode;
            try {
                eventItem = parseEvent(rawEvents[i], item);
            } catch (InvalidEventException e) {
                validationCode = e.getMessage();
            }

            if (eventItem == null) {
                item.errorCode = validationCode == null ? 'invalid_event' : validationCode;
                result.hasValidationErrors = true;
                continue;
            }

            if (eventsById.containsKey(eventItem.eventId)) {
                eventsById.get(eventItem.eventId).add(eventItem);
                EventProcessingItem currentSelection = selectedEventById.get(eventItem.eventId);
                if (eventItem.occurredAt > currentSelection.occurredAt) {
                    Integer selectedPosition = selectedEventPositionById.get(eventItem.eventId);
                    selectedEvents[selectedPosition] = eventItem;
                    selectedEventById.put(eventItem.eventId, eventItem);
                }
                continue;
            }

            eventsById.put(eventItem.eventId, new List<EventProcessingItem>{ eventItem });
            selectedEventById.put(eventItem.eventId, eventItem);
            selectedEventPositionById.put(eventItem.eventId, selectedEvents.size());
            selectedEvents.add(eventItem);
        }

        Set<String> uniqueEventIds = new Set<String>();
        Set<String> accountExternalIds = new Set<String>();
        Set<String> orderIds = new Set<String>();
        for (EventProcessingItem eventItem : selectedEvents) {
            uniqueEventIds.add(eventItem.eventId);
            accountExternalIds.add(eventItem.accountId);
            orderIds.add(eventItem.orderId);
        }

        Map<String, Account> accountsByExternalId = new Map<String, Account>();
        if (!accountExternalIds.isEmpty()) {
            for (Account accountRecord : [
                SELECT Id, Orders_Account_Id__c
                FROM Account
                WHERE Orders_Account_Id__c IN :accountExternalIds
            ]) {
                accountsByExternalId.put(
                    accountRecord.Orders_Account_Id__c,
                    accountRecord
                );
            }
        }

        Map<String, Orders_Event__c> existingReceipts = new Map<String, Orders_Event__c>();
        if (!uniqueEventIds.isEmpty()) {
            for (Orders_Event__c existingReceipt : [
                SELECT Event_Id__c, Event_Type__c, Occurred_At__c,
                    Order_Id__c, Account_Id__c, Applied__c
                FROM Orders_Event__c
                WHERE Event_Id__c IN :uniqueEventIds
                FOR UPDATE
            ]) {
                existingReceipts.put(existingReceipt.Event_Id__c, existingReceipt);
            }
        }

        List<EventProcessingItem> eventsToInsert = new List<EventProcessingItem>();
        List<Orders_Event__c> receiptsToInsert = new List<Orders_Event__c>();
        for (EventProcessingItem eventItem : selectedEvents) {
            if (!accountsByExternalId.containsKey(eventItem.accountId)) {
                eventItem.item.status = 'rejected';
                eventItem.item.errorCode = 'account_not_found';
                result.hasValidationErrors = true;
                continue;
            }
            Orders_Event__c existingReceipt = existingReceipts.get(eventItem.eventId);
            if (
                existingReceipt != null &&
                existingReceipt.Occurred_At__c != null &&
                eventItem.occurredAt <= existingReceipt.Occurred_At__c
            ) {
                eventItem.item.status = 'duplicate';
                continue;
            }

            if (existingReceipt == null) {
                eventItem.receipt = new Orders_Event__c(
                    Event_Id__c = eventItem.eventId,
                    Event_Type__c = eventItem.eventType,
                    Occurred_At__c = eventItem.occurredAt,
                    Order_Id__c = eventItem.orderId,
                    Account_Id__c = eventItem.accountId
                );
                eventsToInsert.add(eventItem);
                receiptsToInsert.add(eventItem.receipt);
            } else {
                eventItem.receipt = existingReceipt;
                eventItem.receiptWasExisting = true;
                eventItem.receipt.Event_Type__c = eventItem.eventType;
                eventItem.receipt.Occurred_At__c = eventItem.occurredAt;
                eventItem.receipt.Order_Id__c = eventItem.orderId;
                eventItem.receipt.Account_Id__c = eventItem.accountId;
            }
        }

        Savepoint batchStart = Database.setSavepoint();
        try {
        if (!receiptsToInsert.isEmpty()) {
            Database.SaveResult[] receiptResults = Database.insert(receiptsToInsert, false);
            for (Integer i = 0; i < receiptResults.size(); i++) {
                EventProcessingItem eventItem = eventsToInsert[i];
                Database.SaveResult receiptResult = receiptResults[i];
                if (receiptResult.isSuccess()) {
                    result.hasNewEvents = true;
                } else if (isDuplicate(receiptResult.getErrors())) {
                    eventItem.item.status = 'duplicate';
                    eventItem.receipt = null;
                } else {
                    eventItem.item.status = 'rejected';
                    eventItem.item.errorCode = 'event_receipt_save_failed';
                    result.hasProcessingFailures = true;
                    eventItem.receipt = null;
                }
            }
        }

        Set<String> acceptedOrderIds = new Set<String>();
        for (EventProcessingItem eventItem : selectedEvents) {
            if (eventItem.receipt != null) {
                acceptedOrderIds.add(eventItem.orderId);
            }
        }

        Map<String, Order__c> existingOrders = new Map<String, Order__c>();
        if (!acceptedOrderIds.isEmpty()) {
            for (Order__c existingOrder : [
                SELECT Id, Name, Orders_Order_Id__c, Last_Event_At__c
                FROM Order__c
                WHERE Orders_Order_Id__c IN :acceptedOrderIds
                FOR UPDATE
            ]) {
                existingOrders.put(existingOrder.Orders_Order_Id__c, existingOrder);
            }
        }

        Map<String, Order__c> projectedOrders = new Map<String, Order__c>();
        Set<String> changedOrderIds = new Set<String>();
        Map<String, List<EventProcessingItem>> eventsByOrder = new Map<String, List<EventProcessingItem>>();

        // Process in payload order so equal timestamps preserve the sender's sequence.
        for (EventProcessingItem eventItem : selectedEvents) {
            if (eventItem.receipt == null) {
                continue;
            }

            if (!projectedOrders.containsKey(eventItem.orderId)) {
                Order__c orderRecord = existingOrders.get(eventItem.orderId);
                if (orderRecord == null) {
                    orderRecord = new Order__c(
                        Orders_Order_Id__c = eventItem.orderId
                    );
                }
                projectedOrders.put(eventItem.orderId, orderRecord);
                eventsByOrder.put(eventItem.orderId, new List<EventProcessingItem>());
            }
            eventsByOrder.get(eventItem.orderId).add(eventItem);

            Order__c projectedOrder = projectedOrders.get(eventItem.orderId);
            if (
                projectedOrder.Last_Event_At__c == null ||
                eventItem.occurredAt >= projectedOrder.Last_Event_At__c
            ) {
                projectedOrder.Name = eventItem.orderFriendlyId;
                projectedOrder.Account__c = accountsByExternalId.get(
                    eventItem.accountId
                ).Id;
                projectedOrder.Status__c = STATUS_BY_TYPE.get(eventItem.eventType);
                projectedOrder.Last_Event_At__c = eventItem.occurredAt;
                projectedOrder.Last_Event_Id__c = eventItem.eventId;
                eventItem.receipt.Applied__c = true;
                eventItem.item.status = 'accepted';
                changedOrderIds.add(eventItem.orderId);
            } else {
                eventItem.item.status = 'stale';
            }
        }

        List<Order__c> ordersToUpsert = new List<Order__c>();
        List<String> orderIdsInDmlOrder = new List<String>();
        for (String orderId : changedOrderIds) {
            ordersToUpsert.add(projectedOrders.get(orderId));
            orderIdsInDmlOrder.add(orderId);
        }

        Set<String> failedOrderIds = new Set<String>();
        if (!ordersToUpsert.isEmpty()) {
            Database.UpsertResult[] orderResults = Database.upsert(
                ordersToUpsert,
                Order__c.Fields.Orders_Order_Id__c,
                false
            );
            for (Integer i = 0; i < orderResults.size(); i++) {
                if (!orderResults[i].isSuccess()) {
                    failedOrderIds.add(orderIdsInDmlOrder[i]);
                    result.hasProcessingFailures = true;
                }
            }
        }

        List<Orders_Event__c> receiptsToDelete = new List<Orders_Event__c>();
        for (String failedOrderId : failedOrderIds) {
            for (EventProcessingItem eventItem : eventsByOrder.get(failedOrderId)) {
                if (eventItem.receipt != null) {
                    if (!eventItem.receiptWasExisting) {
                        receiptsToDelete.add(eventItem.receipt);
                    }
                    eventItem.item.status = 'rejected';
                    eventItem.item.errorCode = 'order_update_failed';
                    eventItem.receipt = null;
                }
            }
        }
        if (!receiptsToDelete.isEmpty()) {
            Database.DeleteResult[] deleteResults = Database.delete(receiptsToDelete, false);
            for (Database.DeleteResult deleteResult : deleteResults) {
                if (!deleteResult.isSuccess()) {
                    throw new BatchProcessingException('Could not roll back failed order receipts');
                }
            }
        }

        List<Orders_Event__c> receiptsToUpdate = new List<Orders_Event__c>();
        for (EventProcessingItem eventItem : selectedEvents) {
            if (eventItem.receipt != null && eventItem.receiptWasExisting) {
                if (eventItem.item.status == 'accepted') {
                    eventItem.receipt.Applied__c = true;
                }
                receiptsToUpdate.add(eventItem.receipt);
            } else if (
                eventItem.receipt != null &&
                eventItem.receipt.Applied__c == true &&
                !failedOrderIds.contains(eventItem.orderId)
            ) {
                receiptsToUpdate.add(eventItem.receipt);
            }
        }
        if (!receiptsToUpdate.isEmpty()) {
            Database.SaveResult[] receiptUpdateResults = Database.update(
                receiptsToUpdate,
                false
            );
            for (Database.SaveResult receiptUpdateResult : receiptUpdateResults) {
                if (!receiptUpdateResult.isSuccess()) {
                    throw new BatchProcessingException('Could not update event receipt');
                }
            }
        }

        for (String eventId : eventsById.keySet()) {
            List<EventProcessingItem> sameIdEvents = eventsById.get(eventId);
            EventProcessingItem selectedEvent = selectedEventById.get(eventId);
            for (EventProcessingItem repeated : sameIdEvents) {
                if (repeated == selectedEvent) {
                    continue;
                }
                if (selectedEvent.item.status == 'rejected') {
                    repeated.item.status = 'rejected';
                    repeated.item.errorCode = selectedEvent.item.errorCode;
                } else {
                    repeated.item.status = 'duplicate';
                }
            }
        }

        result.hasNewEvents = false;
        for (EventProcessingItem eventItem : selectedEvents) {
            if (eventItem.item.status == 'accepted' || eventItem.item.status == 'stale') {
                result.hasNewEvents = true;
                break;
            }
        }

        return result;
        } catch (Exception e) {
            Database.rollback(batchStart);
            throw e;
        }
    }

    // Converts one raw JSON envelope into a validated processing item. 
    private static EventProcessingItem parseEvent(
        Object rawEvent,
        ItemResult item
    ) {
        Map<String, Object> envelope;
        Map<String, Object> eventData;
        Map<String, Object> data;
        try {
            envelope = (Map<String, Object>) rawEvent;
            eventData = (Map<String, Object>) envelope.get('event');
            data = (Map<String, Object>) envelope.get('data');
        } catch (Exception e) {
            throw new InvalidEventException('invalid_event_shape');
        }
        if (envelope == null || eventData == null || data == null) {
            throw new InvalidEventException('invalid_event_shape');
        }

        EventProcessingItem eventItem = new EventProcessingItem();
        eventItem.index = item.index;
        eventItem.item = item;
        eventItem.eventId = stringValue(eventData.get('id'));
        eventItem.eventType = stringValue(eventData.get('type'));
        eventItem.orderId = stringValue(data.get('orderId'));
        eventItem.accountId = stringValue(data.get('accountId'));
        eventItem.orderFriendlyId = stringValue(data.get('orderFriendlyId'));
        item.eventId = eventItem.eventId;

        Object occurredAtValue = eventData.get('occurredAt');
        if (
            String.isBlank(eventItem.eventId) ||
            String.isBlank(eventItem.orderId) ||
            String.isBlank(eventItem.accountId) ||
            String.isBlank(eventItem.orderFriendlyId) ||
            occurredAtValue == null ||
            String.isBlank(String.valueOf(occurredAtValue))
        ) {
            throw new InvalidEventException('missing_required_fields');
        }

        try {
            eventItem.occurredAt = (Datetime) JSON.deserialize(
                '"' + String.valueOf(occurredAtValue) + '"',
                Datetime.class
            );
        } catch (Exception e) {
            throw new InvalidEventException('invalid_occurred_at');
        }

        if (eventItem.occurredAt == null) {
            throw new InvalidEventException('missing_required_fields');
        }
        if (!STATUS_BY_TYPE.containsKey(eventItem.eventType)) {
            throw new InvalidEventException('unsupported_event_type');
        }
        return eventItem;
    }

    // Returns whether a failed insert was caused by a duplicate external ID.
    private static Boolean isDuplicate(
        Database.Error[] errors
    ) {
        for (Database.Error error : errors) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    // Converts a non-null JSON value to its string representation.
    private static String stringValue(
        Object value
    ) {
        return value == null ? null : String.valueOf(value);
    }

    // Contains the per-event outcome returned by the batch processor.
    public class ItemResult {
        public Integer index;
        public String eventId;
        public String status;
        public String errorCode;
    }

    // Contains all item outcomes and summary flags for one processing request.
    public class Result {
        public List<ItemResult> items = new List<ItemResult>();
        public Boolean hasNewEvents = false;
        public Boolean hasValidationErrors = false;
        public Boolean hasProcessingFailures = false;
    }

    // Holds validated event data and its related Salesforce receipt while processing.
    private class EventProcessingItem {
        public Integer index;
        public String eventId;
        public String eventType;
        public String orderId;
        public String accountId;
        public String orderFriendlyId;
        public Datetime occurredAt;
        public ItemResult item;
        public Orders_Event__c receipt;
        public Boolean receiptWasExisting = false;
    }
}
