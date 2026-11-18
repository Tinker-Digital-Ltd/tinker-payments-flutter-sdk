import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinker_payments/tinker_payments.dart';
import 'package:test/test.dart';

http.Response json(Object body,
        [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

Map<String, Object?> ok(Object? data) =>
    {'success': true, 'data': data, 'meta': {}};

Map<String, Object?> err(String code, [String message = 'boom']) => {
      'success': false,
      'error': {'code': code, 'message': message}
    };

void main() {
  late List<http.Request> seen;

  TinkerClient build(http.Response Function(http.Request) handler,
      {String key = 'pk_live_abc',
      String? baseUrl,
      Future<String> Function()? token}) {
    seen = [];
    return TinkerClient(
      publicKey: key,
      baseUrl: baseUrl,
      getCustomerToken: token ?? () async => 'tok1',
      httpClient: MockClient((request) async {
        seen.add(request);
        return handler(request);
      }),
    );
  }

  group('base url', () {
    test('production by default', () async {
      final client = build((_) => json(ok({})));
      await client.getCustomerInfo();
      expect(seen.single.url.toString(),
          'https://api.tinkerpayments.com/v1/client/customer');
    });

    test('sandbox for pk_test_ keys', () async {
      final client = build((_) => json(ok({})), key: 'pk_test_abc');
      await client.getCustomerInfo();
      expect(seen.single.url.toString(),
          'https://sandbox-api.tinkerpayments.com/v1/client/customer');
    });

    test('override gets /v1 appended once', () async {
      final a = build((_) => json(ok({})), baseUrl: 'http://localhost:8080/');
      await a.getCustomerInfo();
      expect(seen.single.url.toString(),
          'http://localhost:8080/v1/client/customer');
      final b = build((_) => json(ok({})), baseUrl: 'http://localhost:8080/v1');
      await b.getCustomerInfo();
      expect(seen.single.url.toString(),
          'http://localhost:8080/v1/client/customer');
    });
  });

  group('methods', () {
    test('getCustomerInfo sends auth headers and unwraps data', () async {
      final client = build((_) => json(ok({'external_customer_id': 'c1'})));
      final info = await client.getCustomerInfo();
      expect(info['external_customer_id'], 'c1');
      expect(seen.single.method, 'GET');
      expect(seen.single.headers['X-Public-Key'], 'pk_live_abc');
      expect(seen.single.headers['Authorization'], 'Bearer tok1');
    });

    test('getEntitlement encodes the identifier', () async {
      final client =
          build((_) => json(ok({'identifier': 'a b', 'is_active': true})));
      final entitlement = await client.getEntitlement('a b');
      expect(entitlement['is_active'], true);
      expect(seen.single.url.path, '/v1/client/entitlements/a%20b');
    });

    test('isEntitled reflects is_active', () async {
      expect(
          await build((_) => json(ok({'is_active': true}))).isEntitled('pro'),
          true);
      expect(
          await build((_) => json(ok({'is_active': false}))).isEntitled('pro'),
          false);
    });

    test('getOfferings', () async {
      final client = build(
          (_) => json(ok({'current_offering_id': 'default', 'offerings': []})));
      final offerings = await client.getOfferings();
      expect(offerings['current_offering_id'], 'default');
      expect(seen.single.url.path, '/v1/client/offerings');
    });

    test('setAttributes posts the attributes', () async {
      final client = build((_) => json(ok({
            'attributes': {'plan': 'x'}
          })));
      final info = await client.setAttributes({'plan': 'x', 'old': null});
      expect(info['attributes'], {'plan': 'x'});
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/v1/client/attributes');
      expect(jsonDecode(seen.single.body), {
        'attributes': {'plan': 'x', 'old': null}
      });
    });

    test('non-object data is wrapped as value', () async {
      final client = build((_) => json(ok([1, 2])));
      expect((await client.getCustomerInfo())['value'], [1, 2]);
    });
  });

  group('token', () {
    test('is cached across requests', () async {
      var calls = 0;
      final client =
          build((_) => json(ok({})), token: () async => 'tok${++calls}');
      await client.getCustomerInfo();
      await client.getOfferings();
      expect(calls, 1);
    });

    test('concurrent requests share one token fetch', () async {
      var calls = 0;
      final client =
          build((_) => json(ok({})), token: () async => 'tok${++calls}');
      await Future.wait([client.getCustomerInfo(), client.getOfferings()]);
      expect(calls, 1);
    });

    test('concurrent TOKEN_INVALID causes one refresh', () async {
      var calls = 0;
      final client = build(
        (request) => request.headers['Authorization'] == 'Bearer tok1'
            ? json(err('TOKEN_INVALID'), 401)
            : json(ok({})),
        token: () async => 'tok${++calls}',
      );
      await Future.wait([client.getCustomerInfo(), client.getOfferings()]);
      expect(calls, 2);
    });

    test('refreshes once on 401 TOKEN_INVALID and retries', () async {
      var calls = 0;
      final client = build(
        (request) => request.headers['Authorization'] == 'Bearer tok1'
            ? json(err('TOKEN_INVALID'), 401)
            : json(ok({'external_customer_id': 'c1'})),
        token: () async => 'tok${++calls}',
      );
      final info = await client.getCustomerInfo();
      expect(info['external_customer_id'], 'c1');
      expect(calls, 2);
      expect(seen.length, 2);
      expect(seen.last.headers['Authorization'], 'Bearer tok2');
    });

    test('retries only once', () async {
      var calls = 0;
      final client = build((_) => json(err('TOKEN_INVALID'), 401),
          token: () async => 'tok${++calls}');
      await expectLater(
          client.getCustomerInfo(),
          throwsA(isA<ApiException>()
              .having((e) => e.errorCode, 'errorCode', 'TOKEN_INVALID')));
      expect(seen.length, 2);
      expect(calls, 2);
    });

    test('does not retry other 401 codes', () async {
      final client = build((_) => json(err('UNAUTHORIZED'), 401));
      await expectLater(client.getCustomerInfo(), throwsA(isA<ApiException>()));
      expect(seen.length, 1);
    });
  });

  group('errors', () {
    test('ApiException carries code, status, request id and retry-after',
        () async {
      final client = build((_) => json(
          {
            'error': {
              'code': 'CUSTOMER_NOT_FOUND',
              'message': 'nope',
              'provider_code': 'p',
              'outcome': 'not_applied'
            }
          },
          404,
          {'x-request-id': 'req1', 'retry-after': '5'}));
      await expectLater(
        client.getCustomerInfo(),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'nope')
            .having((e) => e.code, 'code', 'API_ERROR')
            .having((e) => e.httpStatus, 'httpStatus', 404)
            .having((e) => e.errorCode, 'errorCode', 'CUSTOMER_NOT_FOUND')
            .having((e) => e.providerCode, 'providerCode', 'p')
            .having((e) => e.requestId, 'requestId', 'req1')
            .having((e) => e.retryAfter, 'retryAfter', '5')
            .having((e) => e.outcome, 'outcome', 'not_applied')),
      );
    });

    test('FEATURE_NOT_SUPPORTED maps to its own class', () async {
      final client = build((_) => json({
            'error': {
              'code': 'FEATURE_NOT_SUPPORTED',
              'message': 'no',
              'details': {
                'gateway': 'MPESA',
                'feature': 'refund',
                'alternatives': ['CARD']
              }
            }
          }, 422));
      await expectLater(
        client.getCustomerInfo(),
        throwsA(isA<FeatureNotSupportedException>()
            .having((e) => e.gateway, 'gateway', 'MPESA')
            .having((e) => e.feature, 'feature', 'refund')
            .having((e) => e.alternatives, 'alternatives', ['CARD'])),
      );
    });

    test('success false in a 200 envelope throws ApiException', () async {
      final client = build((_) => json(err('VALIDATION_ERROR', 'bad')));
      await expectLater(
          client.getCustomerInfo(),
          throwsA(
              isA<ApiException>().having((e) => e.message, 'message', 'bad')));
    });

    test('non-JSON error body gives Unknown error', () async {
      final client = build((_) => http.Response('oops', 502));
      await expectLater(
          client.getCustomerInfo(),
          throwsA(isA<ApiException>()
              .having((e) => e.message, 'message', 'Unknown error')));
    });

    test('transport failure becomes NetworkException', () async {
      final client = TinkerClient(
        publicKey: 'pk_live_abc',
        getCustomerToken: () async => 't',
        httpClient: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
          client.getCustomerInfo(), throwsA(isA<NetworkException>()));
    });

    test('invalid JSON on success becomes NetworkException', () async {
      final client = build((_) => http.Response('oops', 200));
      await expectLater(
          client.getCustomerInfo(), throwsA(isA<NetworkException>()));
    });
  });
}
