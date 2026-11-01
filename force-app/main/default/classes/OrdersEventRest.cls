// Exposes the authenticated REST endpoint that receives Orders event batches.
@RestResource(urlMapping='/orders/events/*')
global with sharing class OrdersEventRest {
    // Verifies the request signature, processes its body, and returns an HTTP result.
    @HttpPost
    global static void receive() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        Blob rawBody = request.requestBody;
        String signature = request.headers.get('Orders-Signature');

        String secret = OrdersIntegrationConfig.getSecret();
        if (
            String.isBlank(secret)
        ) {
            respond(
                response,
                500,
                'integration_not_configured'
            );
            return;
        }
        if (
            !OrdersSignature.isValid(
                rawBody,
                signature,
                secret
            )
        ) {
            respond(
                response,
                401,
                'invalid_signature'
            );
            return;
        }

        try {
            OrdersEventProcessor.Result result = OrdersEventProcessor.processBatch(
                rawBody.toString()
            );
            if (result.hasProcessingFailures) {
                response.statusCode = 500;
            } else if (result.hasValidationErrors) {
                response.statusCode = 400;
            } else if (result.hasNewEvents) {
                response.statusCode = 202;
            } else {
                response.statusCode = 200;
            }
            response.addHeader('Content-Type', 'application/json');
            response.responseBody = Blob.valueOf(JSON.serialize(result));
        } catch (OrdersEventProcessor.InvalidBatchException e) {
            respond(
                response,
                400,
                'invalid_batch'
            );
        } catch (Exception e) {
            // generic catch-all for unexpected errors
            respond(
                response,
                500,
                'processing_failed'
            );
        }
    }

    // Sets a simple status and response body for an endpoint error.
    private static void respond(
        RestResponse response,
        Integer status,
        String message
    ) {
        response.statusCode = status;
        response.responseBody = Blob.valueOf(message);
    }
}
