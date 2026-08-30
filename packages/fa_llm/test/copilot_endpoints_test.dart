import 'package:fa_llm/src/copilot/copilot_endpoints.dart';
import 'package:test/test.dart';

void main() {
  group('baseUrlFor', () {
    test('individual maps to api.githubcopilot.com', () {
      expect(
        baseUrlFor(CopilotAccountType.individual),
        'https://api.githubcopilot.com',
      );
    });

    test('business maps to api.business.githubcopilot.com', () {
      expect(
        baseUrlFor(CopilotAccountType.business),
        'https://api.business.githubcopilot.com',
      );
    });

    test('enterprise maps to api.enterprise.githubcopilot.com', () {
      expect(
        baseUrlFor(CopilotAccountType.enterprise),
        'https://api.enterprise.githubcopilot.com',
      );
    });
  });

  group('copilotBaseUrl', () {
    test('defaults to individual', () {
      expect(copilotBaseUrl(), 'https://api.githubcopilot.com');
    });

    test('override wins over the enum', () {
      expect(
        copilotBaseUrl(
          accountType: CopilotAccountType.business,
          baseUrlOverride: 'https://copilot.corp.example.com',
        ),
        'https://copilot.corp.example.com',
      );
    });

    test('empty override is ignored', () {
      expect(
        copilotBaseUrl(baseUrlOverride: ''),
        'https://api.githubcopilot.com',
      );
    });
  });

  group('copilotAccountTypeFromName', () {
    test('parses known names case-insensitively', () {
      expect(
        copilotAccountTypeFromName('individual'),
        CopilotAccountType.individual,
      );
      expect(
        copilotAccountTypeFromName('Business'),
        CopilotAccountType.business,
      );
      expect(
        copilotAccountTypeFromName('ENTERPRISE'),
        CopilotAccountType.enterprise,
      );
    });

    test('null or empty falls back to individual', () {
      expect(copilotAccountTypeFromName(null), CopilotAccountType.individual);
      expect(copilotAccountTypeFromName(''), CopilotAccountType.individual);
    });

    test('unknown plan throws ArgumentError', () {
      expect(() => copilotAccountTypeFromName('family'), throwsArgumentError);
    });
  });

  test('default client id matches the VS Code Copilot Chat plugin', () {
    expect(copilotDefaultClientId, 'Iv1.b507a08c87ecfe98');
  });
}
