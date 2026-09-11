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
  <VersionOverrides xmlns="http://schemas.microsoft.com/office/mailappversionoverrides" xsi:type="VersionOverridesV1_0">
    <Hosts>
      <Host xsi:type="MailHost">
        <DesktopFormFactor>
          <ExtensionPoint xsi:type="MessageReadCommandSurface">
            <OfficeTab id="TabDefault">
              <Group id="fa-read-group">
                <Label resid="groupLabel"/>
                <Control xsi:type="Button" id="fa-read-open-pane">
                  <Label resid="paneButtonLabel"/>
                  <Supertip>
                    <Title resid="paneButtonTitle"/>
                    <Description resid="paneButtonDesc"/>
                  </Supertip>
                  <Icon>
                    <bt:Image size="16" resid="icon16"/>
                    <bt:Image size="32" resid="icon32"/>
                    <bt:Image size="80" resid="icon80"/>
                  </Icon>
                  <Action xsi:type="ShowTaskpane">
                    <SourceLocation resid="taskpaneUrl"/>
                  </Action>
                </Control>
              </Group>
            </OfficeTab>
          </ExtensionPoint>
          <ExtensionPoint xsi:type="MessageComposeCommandSurface">
            <OfficeTab id="TabDefault">
              <Group id="fa-compose-group">
                <Label resid="groupLabel"/>
                <Control xsi:type="Button" id="fa-compose-open-pane">
                  <Label resid="paneButtonLabel"/>
                  <Supertip>
                    <Title resid="paneButtonTitle"/>
                    <Description resid="paneButtonDesc"/>
                  </Supertip>
                  <Icon>
                    <bt:Image size="16" resid="icon16"/>
                    <bt:Image size="32" resid="icon32"/>
                    <bt:Image size="80" resid="icon80"/>
                  </Icon>
                  <Action xsi:type="ShowTaskpane">
                    <SourceLocation resid="taskpaneUrl"/>
                  </Action>
                </Control>
              </Group>
            </OfficeTab>
          </ExtensionPoint>
        </DesktopFormFactor>
      </Host>
    </Hosts>
    <Resources>
      <bt:Images>
        <bt:Image id="icon16" DefaultValue="https://fa1.dev/outlook/icons/fa-16.png"/>
        <bt:Image id="icon32" DefaultValue="https://fa1.dev/outlook/icons/fa-32.png"/>
        <bt:Image id="icon80" DefaultValue="https://fa1.dev/outlook/icons/fa-80.png"/>
      </bt:Images>
      <bt:Urls>
        <bt:Url id="taskpaneUrl" DefaultValue="https://fa1.dev/outlook/index.html"/>
      </bt:Urls>
      <bt:ShortStrings>
        <bt:String id="groupLabel" DefaultValue="fa"/>
        <bt:String id="paneButtonLabel" DefaultValue="fa"/>
        <bt:String id="paneButtonTitle" DefaultValue="fa"/>
      </bt:ShortStrings>
      <bt:LongStrings>
        <bt:String id="paneButtonDesc" DefaultValue="Open the fa taskpane."/>
      </bt:LongStrings>
    </Resources>
  </VersionOverrides>
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

  test('classic-only manifest rejected: no command surface (issue #143)', () {
    // Exactly the bug: the add-in installed but stayed invisible in new
    // Outlook (Monarch) and modern OWA — classic FormSettings only.
    final classic = _validProd.substring(
      0,
      _validProd.indexOf('  <VersionOverrides'),
    );
    final report = validateOutlookManifest('$classic</OfficeApp>');
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('no VersionOverrides'));
  });

  test('VersionOverrides without MessageReadCommandSurface rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        'xsi:type="MessageReadCommandSurface"',
        'xsi:type="MessageComposeCommandSurface"',
      ),
    );
    expect(report.ok, isFalse);
    expect(
      report.issues.join('\n'),
      contains('must declare MessageReadCommandSurface'),
    );
  });

  test('command Icon without a 80 px bt:Image rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst('<bt:Image size="80" resid="icon80"/>', ''),
    );
    expect(report.ok, isFalse);
    expect(
      report.issues.join('\n'),
      contains('command Icon must declare a 80 px bt:Image'),
    );
  });

  test('unresolved resid reference rejected', () {
    final report = validateOutlookManifest(
      _validProd.replaceFirst('resid="taskpaneUrl"', 'resid="goneUrl"'),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('unresolved resid reference'));
  });

  test('VersionOverrides Host as Mailbox rejected, must be MailHost', () {
    // The override Host type enum is MailHost; Mailbox makes the OMEX
    // validation gateway reject the whole package ("Package Type Not
    // Identified").
    final report = validateOutlookManifest(
      _validProd.replaceFirst(
        '<Host xsi:type="MailHost">',
        '<Host xsi:type="Mailbox">',
      ),
    );
    expect(report.ok, isFalse);
    expect(report.issues.join('\n'), contains('MailHost'));
  });
}
