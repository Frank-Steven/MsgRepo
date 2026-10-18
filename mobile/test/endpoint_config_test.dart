import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';

/// N2 诊断回归：Base URL 拼接与常见配置错误的前置提示。
void main() {
  group('joinEndpointUrl', () {
    test('去掉尾部斜杠，避免 //', () {
      expect(AiClient.joinEndpointUrl('https://api.deepseek.com/', 'chat/completions'),
          'https://api.deepseek.com/chat/completions');
      expect(AiClient.joinEndpointUrl('https://api.deepseek.com///', 'models'),
          'https://api.deepseek.com/models');
      expect(AiClient.joinEndpointUrl(' https://a.com/v1 ', 'models'),
          'https://a.com/v1/models');
    });
  });

  group('endpointConfigHint', () {
    test('正常的 OpenAI 兼容地址不报警', () {
      expect(AiClient.endpointConfigHint('https://api.deepseek.com'), isNull);
      expect(AiClient.endpointConfigHint('https://api.deepseek.com/v1'), isNull);
      expect(AiClient.endpointConfigHint('http://127.0.0.1:8080/v1'), isNull);
    });

    test('Anthropic 格式地址给出明确提示（真实踩过的坑）', () {
      final hint = AiClient.endpointConfigHint('https://api.deepseek.com/anthropic');
      expect(hint, isNotNull);
      expect(hint, contains('Anthropic'));
      expect(hint, contains('https://api.deepseek.com'));
      expect(
          AiClient.endpointConfigHint('https://api.deepseek.com/anthropic/v1'),
          isNotNull);
    });

    test('空地址 / 缺协议头也会提示', () {
      expect(AiClient.endpointConfigHint(''), isNotNull);
      expect(AiClient.endpointConfigHint('api.deepseek.com'), isNotNull);
    });
  });

  group('describeUpstreamError（N2）', () {
    test('优先取 error.message，而不是整段 JSON', () {
      const body = '{"error":{"message":"The supported API model names are deepseek-flash '
          'and deepseek-v4-pro","type":"invalid_request_error"}}';
      expect(AiClient.describeUpstreamError(body),
          'The supported API model names are deepseek-flash and deepseek-v4-pro');
    });

    test('没有 error 字段时退回 message 或原文', () {
      expect(AiClient.describeUpstreamError('{"message":"bad model"}'), 'bad model');
      expect(AiClient.describeUpstreamError('plain text error'), 'plain text error');
      expect(AiClient.describeUpstreamError(''), '');
    });

    test('超长非 JSON 正文按 240 字截断', () {
      final long = 'x' * 300;
      final out = AiClient.describeUpstreamError(long);
      expect(out.length, 241);
      expect(out.endsWith('…'), isTrue);
    });
  });

  group('shouldRetryPerMessage（P1-2 收紧）', () {
    test('模型输出不合格 → 值得逐条重试', () {
      expect(AiClient.shouldRetryPerMessage('模型未返回 JSON 数组：xxx'), isTrue);
      expect(AiClient.shouldRetryPerMessage('模型输出 JSON 解析失败：FormatException'), isTrue);
    });

    test('配置/网络类错误 → 不逐条重发（避免 N 份全量提示词）', () {
      expect(
          AiClient.shouldRetryPerMessage(
              '远程接口返回 400 @ https://api.deepseek.com/chat/completions：The supported API model names are …'),
          isFalse);
      expect(AiClient.shouldRetryPerMessage('HTTP 401 @ https://x.com/models：invalid key'), isFalse);
      expect(AiClient.shouldRetryPerMessage('SocketException: Failed host lookup'), isFalse);
      expect(AiClient.shouldRetryPerMessage('TimeoutException after 0:03:00'), isFalse);
    });
  });
}