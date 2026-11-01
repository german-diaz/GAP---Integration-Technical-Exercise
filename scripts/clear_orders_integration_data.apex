// Deletes all integration order projections and event receipts in this org.
// execute in Anonymous Apex to clear all integration data.

List<Order__c> orders = [
    SELECT Id
    FROM Order__c
];

List<Orders_Event__c> eventReceipts = [
    SELECT Id
    FROM Orders_Event__c
];


delete orders;
delete eventReceipts;
