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
}
