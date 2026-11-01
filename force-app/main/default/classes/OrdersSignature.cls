// reads the request body and secret to verify the HMAC signature
public class OrdersSignature {
    // Checks whether the supplied hex HMAC matches the request body and secret.
    public static Boolean isValid(
        Blob body,
        String suppliedHex,
        String secret
    ) {
        if (
            body == null || String.isBlank(suppliedHex) || String.isBlank(secret)
        ) {
            return false;
        }
        String expected = EncodingUtil.convertToHex(
            Crypto.generateMac(
                'HmacSHA256',
                body,
                Blob.valueOf(secret)
            )
        ).toLowerCase();
        String actual = suppliedHex.trim().toLowerCase();
        if (
            actual.length() != expected.length()
        ) {
            return false;
        }
        // Compare every character
        Integer difference = 0;
        for (Integer i = 0; i < expected.length(); i++) {
            if (
                expected.substring(
                    i,
                    i + 1
                ) != actual.substring(
                    i,
                    i + 1
                )
            ) {
                difference++;
            }
        }
        return difference == 0;
    }
}
