import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

typedef JsonMap = Map<String, dynamic>;

class TinkerClient {
  TinkerClient({
    required this.publicKey,
    required this.getCustomerToken,
    String? baseUrl,
    String? paywallBaseUrl,
    http.Client? httpClient,
  })  : baseUrl = _resolveBaseUrl(publicKey, baseUrl),
        paywallBaseUrl = _resolvePaywallBaseUrl(paywallBaseUrl),
        _ownsHttp = httpClient == null,
        _http = httpClient ?? http.Client();

  static const productionBaseUrl = 'https://api.tinkerpayments.com';
  static const sandboxBaseUrl = 'https://sandbox-api.tinkerpayments.com';
  static const defaultPaywallBaseUrl = 'https://tinkerpayments.com';
  static const _apiVersionPath = '/v1';

  final String publicKey;
  final Future<String> Function() getCustomerToken;
  final String baseUrl;
  final String paywallBaseUrl;
  final http.Client _http;
  final bool _ownsHttp;
  String? _token;
  Future<String>? _pending;

  Future<JsonMap> getCustomerInfo() => _request('GET', 'client/customer');

  Future<JsonMap> getEntitlement(String identifier) =>
      _request('GET', 'client/entitlements/${Uri.encodeComponent(identifier)}');

  Future<bool> isEntitled(String identifier) async =>
      (await getEntitlement(identifier))['is_active'] == true;

  Future<JsonMap> getOfferings() => _request('GET', 'client/offerings');

  Future<JsonMap> setAttributes(Map<String, String?> attributes) =>
      _request('POST', 'client/attributes', {'attributes': attributes});

  Future<String> paywallUrl(
      {required String returnUrl, String? offering}) async {
    final token = await _currentToken();
    return Uri.parse('$paywallBaseUrl/paywall').replace(queryParameters: {
      'pk': publicKey,
      'token': token,
      'return_url': returnUrl,
      if (offering != null && offering.isNotEmpty) 'offering': offering,
    }).toString();
  }

  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<String> _currentToken() async {
    final token = _token;
    if (token != null) return token;
    try {
      return await (_pending ??= _fetchToken());
    } catch (error) {
      throw NetworkException(
          'Failed to communicate with Tinker API: $error', error);
    }
  }

  Future<String> _fetchToken() async {
    try {
      final token = await Future.sync(getCustomerToken);
      if (token.isEmpty) {
        throw TinkerException(
            'Customer token must not be empty', 'INVALID_TOKEN');
      }
      _token = token;
      return token;
    } finally {
      _pending = null;
    }
  }

  Future<JsonMap> _request(String method, String path, [JsonMap? body]) async {
    final token = await _currentToken();
    try {
      return await _send(method, path, body, token);
    } on ApiException catch (error) {
      if (error.status != 401 || error.errorCode != 'TOKEN_INVALID') rethrow;
      if (_token == token) _token = null;
      return _send(method, path, body, await _currentToken());
    }
  }

  Future<JsonMap> _send(
      String method, String path, JsonMap? body, String token) async {
    final request = http.Request(method, Uri.parse('$baseUrl/$path'))
      ..headers.addAll({
        'X-Public-Key': publicKey,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      });
    if (body != null && body.isNotEmpty) request.body = jsonEncode(body);

    try {
      final response =
          await http.Response.fromStream(await _http.send(request));
      final text = utf8.decode(response.bodyBytes);
      Object? result;
      try {
        result = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      } on FormatException {
        if (response.statusCode >= 400) {
          throw ApiException.from('Unknown error',
              status: response.statusCode, headers: response.headers);
        }
        rethrow;
      }

      if (response.statusCode >= 400) {
        throw ApiException.from(_errorMessage(result),
            status: response.statusCode,
            details: result,
            headers: response.headers);
      }

      if (result is JsonMap && result.containsKey('success')) {
        if (result['success'] == false) {
          throw ApiException.from(_errorMessage(result),
              status: response.statusCode,
              details: result,
              headers: response.headers);
        }
        final data = result['data'];
        return data is JsonMap ? data : {'value': data};
      }

      return result is JsonMap ? result : {};
    } on ApiException {
      rethrow;
    } catch (error) {
      throw NetworkException(
          'Failed to communicate with Tinker API: $error', error);
    }
  }

  static String _errorMessage(Object? result) {
    if (result is JsonMap) {
      final error = result['error'];
      if (error is JsonMap) {
        return _truthy(error['message']) ??
            _truthy(error['code']) ??
            'Unknown error';
      }
      final message = _truthy(result['message']);
      if (message != null) return message;
    }
    return 'Unknown error';
  }

  static String? _truthy(Object? value) =>
      value == null || value == '' || value == false ? null : value.toString();

  static String _resolveBaseUrl(String publicKey, String? override) {
    if (!publicKey.startsWith('pk_')) {
      throw TinkerException(
          'publicKey must start with pk_', 'INVALID_PUBLIC_KEY');
    }
    var url = override == null || override.trim().isEmpty
        ? (publicKey.startsWith('pk_test_')
            ? sandboxBaseUrl
            : productionBaseUrl)
        : override;
    url = url.replaceFirst(RegExp(r'/+$'), '');
    return url.endsWith(_apiVersionPath) ? url : '$url$_apiVersionPath';
  }

  static String _resolvePaywallBaseUrl(String? override) =>
      (override == null || override.trim().isEmpty
              ? defaultPaywallBaseUrl
              : override)
          .replaceFirst(RegExp(r'/+$'), '');
}
