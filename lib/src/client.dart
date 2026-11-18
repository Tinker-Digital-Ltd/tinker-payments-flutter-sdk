import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

typedef JsonMap = Map<String, dynamic>;

class TinkerClient {
  TinkerClient({
    required this.publicKey,
    required this.getCustomerToken,
    String? baseUrl,
    http.Client? httpClient,
  })  : baseUrl = _resolveBaseUrl(publicKey, baseUrl),
        _http = httpClient ?? http.Client();

  static const productionBaseUrl = 'https://api.tinkerpayments.com';
  static const sandboxBaseUrl = 'https://sandbox-api.tinkerpayments.com';
  static const _apiVersionPath = '/v1';

  final String publicKey;
  final Future<String> Function() getCustomerToken;
  final String baseUrl;
  final http.Client _http;
  String? _token;

  Future<JsonMap> getCustomerInfo() => _request('GET', 'client/customer');

  Future<JsonMap> getEntitlement(String identifier) =>
      _request('GET', 'client/entitlements/${Uri.encodeComponent(identifier)}');

  Future<bool> isEntitled(String identifier) async =>
      (await getEntitlement(identifier))['is_active'] == true;

  Future<JsonMap> getOfferings() => _request('GET', 'client/offerings');

  Future<JsonMap> setAttributes(Map<String, String?> attributes) =>
      _request('POST', 'client/attributes', {'attributes': attributes});

  void close() => _http.close();

  Future<JsonMap> _request(String method, String path, [JsonMap? body]) async {
    try {
      return await _send(method, path, body);
    } on ApiException catch (error) {
      if (error.status != 401 || error.errorCode != 'TOKEN_INVALID') rethrow;
      _token = null;
      return _send(method, path, body);
    }
  }

  Future<JsonMap> _send(String method, String path, JsonMap? body) async {
    final token = _token ??= await getCustomerToken();
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
    var url = override == null || override.trim().isEmpty
        ? (publicKey.startsWith('pk_test_')
            ? sandboxBaseUrl
            : productionBaseUrl)
        : override;
    url = url.replaceFirst(RegExp(r'/+$'), '');
    return url.endsWith(_apiVersionPath) ? url : '$url$_apiVersionPath';
  }
}
