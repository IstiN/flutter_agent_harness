// Synthetic-fixture tests for the Outlook manifest validator (issue #89,
// AC1 / UT-manifest): one valid prod manifest, then one corruption per
// check the validator owns.
import 'package:test/test.dart';

import '../src/manifest.dart';

const _validProd = '''
<?xml version="1.0" encoding="UTF-8"?>
<OfficeApp
  xmlns="http://schemas.microsoft.com/office/appforoffice/1.1"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xmlns:bt="http://schemas.microsoft.com/office/officeappbasictypes/1.0"
  xsi:type="MailApp">
  <Id>4D907D39-1309-4EF7-953B-13A88FAF1C60</Id>
  <Version>1.0.0.0</Version>
  <ProviderName>Flutter Agent Harness</ProviderName>
  <DefaultLocale>en-US</DefaultLocale>
  <DisplayName DefaultValue="fa"/>
  <Description DefaultValue="fa — your agent in Outlook."/>
  <IconUrl DefaultValue="https://fa1.dev/outlook/icons/fa-64.png"/>
  <HighResolutionIconUrl DefaultValue="https://fa1.dev/outlook/icons/fa-128.png"/>
  <SupportUrl DefaultValue="https://fa1.dev/outlook/support.html"/>
  <AppDomains>
    <AppDomain>https://fa1.dev</AppDomain>
  </AppDomains>
  <Hosts>
    <Host Name="Mailbox"/>
  </Hosts>
  <Requirements>
    <Sets DefaultMinVersion="1.8">
      <Set Name="Mailbox" MinVersion="1.8"/>
    </Sets>
  </Requirements>
  <FormSettings>
    <Form xsi:type="ItemRead">
      <DesktopSettings>
        <SourceLocation DefaultValue="https://fa1.dev/outlook/index.html"/>
        <RequestedHeight>400</RequestedHeight>
      </DesktopSettings>
    </Form>
  </FormSettings>
  <Permissions>ReadWriteItem</Permissions>
  <Rule xsi:type="RuleCollection" Mode="Or">
    <Rule xsi:type="ItemIs" ItemType="Message" FormType="Read"/>
  </Rule>
</OfficeApp>
''';

String _dev() =>
    _validProd.replaceAll('https://fa1.dev', 'https://localhost:8443');

void main() {
  test('valid prod manifest passes', () {
    final report = validateOutlookManifest(_validProd);
    expect(report.issues, isEmpty);
    expect(report.ok, isTrue);
  });

  test('dev shape passes with dev:true and fails without the flag', () {
    expect(validateOutlookManifest(_dev(), dev: true).ok, isTrue);
    expect(validateOutlookManifest(_dev()).ok, isFalse);
  });

  test('prod shape fails under dev:true (mixed shapes are an issue)', () {
    expect(validateOutlookManifest(_validProd, dev: true).ok, isFalse);
  });

  test('http:// URL rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        'https://fa1.dev/outlook/icons/fa-64.png',
        'http://fa1.dev/outlook/icons/fa-64.png',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('non-https'));
  });

  test('foreign host rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        'https://fa1.dev/outlook/index.html',
        'https://evil.example/outlook/index.html',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('evil.example'));
  });

  test('path outside /outlook/ rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        'https://fa1.dev/outlook/index.html',
        'https://fa1.dev/evil.html',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('/outlook/'));
  });

  test('ReadWriteMailbox rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '<Permissions>ReadWriteItem</Permissions>',
        '<Permissions>ReadWriteMailbox</Permissions>',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('ReadWriteMailbox'));
  });

  test('second Host (Word) rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '<Host Name="Mailbox"/>',
        '<Host Name="Mailbox"/><Host Name="Word"/>',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('exactly one'));
  });

  test('MobileFormFactor rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '</OfficeApp>',
        '<MobileFormFactor><Form xsi:type="ItemRead"/></MobileFormFactor></OfficeApp>',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('MobileFormFactor'));
  });

  test('ReadItem-only rejected: derived tiers must be exactly the two', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '<Permissions>ReadWriteItem</Permissions>',
        '<Permissions>ReadItem</Permissions>',
      ),
    );
    expect(report.ok, isFalse);
    expect(
      report.issues.join('\n'),
      contains('exactly {ReadItem, ReadWriteItem}'),
    );
  });

  test('benign XML comment passes', () {
    final report = validateOutlookManifest('<!-- fa taskpane -->$_validProd');
    expect(report.ok, isTrue);
  });

  test('"--" inside an XML comment rejected (issue #131)', () {
    // Exactly the bug: a comment naming the --dev build flag made Outlook
    // reject the whole manifest as malformed XML.
    final report = validateOutlookManifest(
      '<!-- build with the --dev flag -->$_validProd',
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('"--"'));
  });

  test('unterminated XML comment rejected', () {
    final report = validateOutlookManifest('<!-- oops$_validProd');
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('unterminated XML comment'));
  });

  test('RequestedHeight inside an ItemEdit form rejected (issue #131)', () {
    // The Office schema allows only SourceLocation in the compose form's
    // DesktopSettings; Outlook's upload validation rejects the rest.
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '</FormSettings>',
        '<Form xsi:type="ItemEdit"><DesktopSettings>'
            '<SourceLocation DefaultValue="https://fa1.dev/outlook/index.html"/>'
            '<RequestedHeight>400</RequestedHeight>'
            '</DesktopSettings></Form></FormSettings>',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('not allowed in ItemEdit'));
  });
}
