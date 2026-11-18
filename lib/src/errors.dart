class TinkerException implements Exception {
  TinkerException(this.message,
      [this.code = 'TINKER_ERROR', this.status, this.details]);

  final String message;
  final String code;
  final int? status;
  final Object? details;

  @override
  String toString() => '$runtimeType($code): $message';
}

class ApiException extends TinkerException {
  ApiException(String message,
      {int? status, Object? details, Map<String, String>? headers})
      : super(message, 'API_ERROR', status, details) {
    final error = _asMap(_asMap(details)['error']);
    String? field(String name) =>
        error[name] is String ? error[name] as String : null;
    errorCode = field('code');
    providerCode = field('provider_code');
    requestId = field('request_id') ?? _header(headers, 'x-request-id');
    retryAfter = _header(headers, 'retry-after');
    outcome = field('outcome');
  }

  late final String? errorCode;
  late final String? providerCode;
  late final String? requestId;
  late final String? retryAfter;
  late final String? outcome;

  int? get httpStatus => status;

  factory ApiException.from(String message,
      {int? status, Object? details, Map<String, String>? headers}) {
    final error = ApiException(message,
        status: status, details: details, headers: headers);
    return error.errorCode == 'FEATURE_NOT_SUPPORTED'
        ? FeatureNotSupportedException(message,
            status: status, details: details, headers: headers)
        : error;
  }
}

class FeatureNotSupportedException extends ApiException {
  FeatureNotSupportedException(super.message,
      {super.status, super.details, super.headers}) {
    final info = _asMap(_asMap(_asMap(details)['error'])['details']);
    gateway = info['gateway'] is String ? info['gateway'] as String : null;
    feature = info['feature'] is String ? info['feature'] as String : null;
    alternatives = info['alternatives'] is List
        ? (info['alternatives'] as List).whereType<String>().toList()
        : [];
  }

  late final String? gateway;
  late final String? feature;
  late final List<String> alternatives;
}

class NetworkException extends TinkerException {
  NetworkException(String message, this.cause)
      : super(message, 'NETWORK_ERROR');

  final Object cause;
}

class InvalidPayloadException extends TinkerException {
  InvalidPayloadException(String message, [Object? details])
      : super(message, 'INVALID_PAYLOAD', null, details);
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

String? _header(Map<String, String>? headers, String name) {
  final value = headers?[name];
  return value == null || value.isEmpty ? null : value;
}
