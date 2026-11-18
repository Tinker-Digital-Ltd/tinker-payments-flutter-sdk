# Tinker Payments Flutter SDK

Client SDK for apps. Pure Dart, no platform channels. It never holds your app secret: it uses your public key and a short-lived customer token.

## Install

```yaml
dependencies:
  tinker_payments:
    git:
      url: https://github.com/Tinker-Digital-Ltd/tinker-payments-flutter-sdk.git
```

## Initialise

Your backend mints the customer token with the server SDK (`POST /v1/merchant/customers/{id}/token`). The client calls your callback for the token, caches it, and on a 401 `TOKEN_INVALID` fetches a new one and retries once.

```dart
import 'package:tinker_payments/tinker_payments.dart';

final client = TinkerClient(
  publicKey: 'pk_live_...',
  getCustomerToken: () async => fetchTokenFromYourBackend(),
);
```

`pk_test_` keys use `https://sandbox-api.tinkerpayments.com`; others use `https://api.tinkerpayments.com`. Pass `baseUrl` to override (`/v1` is appended if missing). Pass `httpClient` to inject a `package:http` client.

## Usage

```dart
final info = await client.getCustomerInfo();
final pro = await client.getEntitlement('pro');
final entitled = await client.isEntitled('pro');
final offerings = await client.getOfferings();
await client.setAttributes({'plan': 'beta', 'old_key': null});
```

Responses are the API's `data` objects as `Map<String, dynamic>` with snake_case keys.

## Errors

All extend `TinkerException` (`message`, `code`, `status`, `details`).

- `ApiException` (`code` `API_ERROR`): `httpStatus`, `errorCode`, `providerCode`, `requestId`, `retryAfter`, `outcome`.
- `FeatureNotSupportedException`: `gateway`, `feature`, `alternatives`.
- `NetworkException` (`NETWORK_ERROR`): `cause`.
- `InvalidPayloadException` (`INVALID_PAYLOAD`).

## Purchases

Purchases are started from your backend with the server SDK's payment initiate, using `productId`, `externalCustomerId` and `presentedOfferingId`.

## Development

```sh
dart pub get
dart analyze
dart test
```
