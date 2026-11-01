// Reads the secret from custom settings
public without sharing class OrdersIntegrationConfig {
    public static String getSecret() {
        Orders_Integration_Settings__c settings = Orders_Integration_Settings__c.getOrgDefaults();
        return settings == null
            ? null
            : settings.Shared_Secret__c;
    }
}
