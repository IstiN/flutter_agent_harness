// Contacts widget — system contacts via the jsr.fa.contacts bridge.
// Search field + results list, tap → detail card with call/SMS buttons
// (SMS opens a textField for the message), add-contact form,
// permission-aware error states.
(function() {
  var t = jsr.theme;
  var query = '';
  var results = [];
  var loading = true;
  var error = null; // { kind: 'permission'|'error', message: string }
  var selected = null; // index into results, or null for the list
  var smsOpen = false; // detail card: SMS textField visible
  var smsText = '';
  var form = null; // null, or { name, phone, email } — raw text until save
  var notice = null; // transient confirmation/error line

  function fail(msg) {
    loading = false;
    results = [];
    error = {
      kind: msg.indexOf('permission') >= 0 ? 'permission' : 'error',
      message: msg,
    };
  }

  function search() {
    loading = true;
    error = null;
    selected = null;
    render();
    jsr.fa.contacts.search({ query: query }).then(function(result) {
      if (result && result.__error) {
        fail(String(result.__error));
      } else {
        loading = false;
        results = (result && result.contacts) || [];
      }
      render();
    }, function(e) {
      fail(String(e));
      render();
    });
  }

  function navButton(icon, action) {
    return {
      type: 'inkWell', onTap: action, borderRadius: 8,
      child: {
        type: 'container',
        width: 36, height: 36, alignment: 'center',
        decoration: {
          color: t.surface, borderRadius: 8,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'icon', name: icon, color: t.text, size: 18 },
      },
    };
  }

  function contactRow(contact, index) {
    var phone = contact.phones && contact.phones.length
      ? contact.phones[0]
      : 'no phone';
    return {
      type: 'inkWell', onTap: 'contact_' + index, borderRadius: 12,
      child: {
        type: 'container',
        margin: [16, 0, 16, 8],
        padding: [12, 12, 12, 12],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.border, width: 1 },
        },
        child: { type: 'row', crossAxisAlignment: 'center', children: [
          { type: 'container',
            width: 36, height: 36,
            margin: [0, 0, 10, 0],
            alignment: 'center',
            decoration: { color: t.accent, borderRadius: 18 },
            child: { type: 'icon', name: 'person', color: t.onAccent,
              size: 20 },
          },
          { type: 'expanded', child: {
            type: 'column', crossAxisAlignment: 'start', children: [
              { type: 'text', data: contact.name || '(no name)',
                style: { color: t.text, fontSize: 14, fontWeight: 'w600' } },
              { type: 'sizedBox', height: 2 },
              { type: 'text', data: phone,
                style: { color: t.muted, fontSize: 11 } },
            ] } },
          { type: 'icon', name: 'arrow_forward', color: t.muted, size: 16 },
        ] },
      },
    };
  }

  function detailCard() {
    var contact = results[selected];
    if (!contact) return { type: 'sizedBox', height: 0 };
    var phones = contact.phones || [];
    var emails = contact.emails || [];
    var hasPhone = phones.length > 0;
    var lines = [
      { type: 'text', data: contact.name || '(no name)',
        style: { color: t.text, fontSize: 16, fontWeight: 'w700' } },
      { type: 'sizedBox', height: 8 },
    ];
    var i;
    for (i = 0; i < phones.length; i++) {
      lines.push({ type: 'text', data: phones[i],
        style: { color: t.accent, fontSize: 13, fontWeight: 'w600' } });
      lines.push({ type: 'sizedBox', height: 2 });
    }
    for (i = 0; i < emails.length; i++) {
      lines.push({ type: 'text', data: emails[i],
        style: { color: t.muted, fontSize: 12 } });
      lines.push({ type: 'sizedBox', height: 2 });
    }
    if (!hasPhone && !emails.length) {
      lines.push({ type: 'text', data: 'No phone numbers or emails.',
        style: { color: t.muted, fontSize: 12 } });
    }
    lines.push({ type: 'sizedBox', height: 12 });
    lines.push({ type: 'row', children: [
      { type: 'button', label: 'Call', onPressed: 'call',
        color: t.accent },
      { type: 'sizedBox', width: 8 },
      { type: 'button', label: 'SMS', onPressed: 'sms_open',
        color: t.accent2 },
    ] });
    if (smsOpen) {
      lines.push({ type: 'sizedBox', height: 10 });
      lines.push({ type: 'textField', hint: 'Message…', value: smsText,
        onChange: 'sms_change', onSubmit: 'sms_send' });
      lines.push({ type: 'sizedBox', height: 8 });
      lines.push({ type: 'row', mainAxisAlignment: 'end', children: [
        { type: 'button', label: 'Send SMS', onPressed: 'sms_send',
          color: t.accent },
      ] });
    }
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.accent, width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'stretch',
          children: lines },
      },
    };
  }

  function formField(hint, value, onChange) {
    return {
      type: 'textField', hint: hint, value: value, onChange: onChange,
    };
  }

  function formCard() {
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: t.accent, width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'stretch', children: [
          { type: 'text', data: 'New contact',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600' } },
          { type: 'sizedBox', height: 10 },
          formField('Name', form.name, 'form_name'),
          { type: 'sizedBox', height: 8 },
          formField('Phone', form.phone, 'form_phone'),
          { type: 'sizedBox', height: 8 },
          formField('Email', form.email, 'form_email'),
          { type: 'sizedBox', height: 12 },
          { type: 'row', mainAxisAlignment: 'end', children: [
            { type: 'textButton', text: 'Cancel', onTap: 'form_cancel' },
            { type: 'sizedBox', width: 8 },
            { type: 'button', label: 'Add', onPressed: 'form_save',
              color: t.accent },
          ] },
        ] },
      },
    };
  }

  function emptyState() {
    return {
      type: 'padding', padding: [16, 40, 16, 24], child: {
        type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'person', color: t.muted, size: 40 },
          { type: 'sizedBox', height: 10 },
          { type: 'text', data: 'No contacts',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 4 },
          { type: 'text', data: query
              ? 'Nobody matches "' + query + '".'
              : 'Your address book is empty.',
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
        ] },
    };
  }

  function errorCard() {
    var isPerm = error.kind === 'permission';
    return {
      type: 'padding', padding: [16, 16, 16, 16], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: isPerm ? t.accent : '#ef4444', width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: isPerm ? 'lock' : 'warning',
            color: isPerm ? t.accent : '#ef4444', size: 32 },
          { type: 'sizedBox', height: 10 },
          { type: 'text',
            data: isPerm ? 'Contacts permission needed' : 'Could not load contacts',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text',
            data: isPerm
              ? 'Grant the contacts permission: tap the shield icon in ' +
                'this app\'s header and enable "Contacts".'
              : error.message,
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
          { type: 'sizedBox', height: 12 },
          { type: 'button', label: 'Retry', onPressed: 'retry',
            color: t.accent },
        ] },
      },
    };
  }

  function body() {
    if (form) return formCard();
    if (selected !== null) return detailCard();
    if (loading) {
      return { type: 'padding', padding: [0, 48, 0, 48], child: {
        type: 'center', child: {
          type: 'circularProgressIndicator', size: 24 } } };
    }
    if (error) return errorCard();
    if (!results.length) return emptyState();
    return {
      type: 'expanded', child: {
        type: 'listView', shrinkWrap: false,
        children: results.map(contactRow),
      },
    };
  }

  function noticeLine() {
    if (!notice) return { type: 'sizedBox', height: 0 };
    return { type: 'padding', padding: [16, 0, 16, 8], child: {
      type: 'text', data: notice,
      style: { color: t.muted, fontSize: 12 } } };
  }

  function render() {
    jsr.render({
      type: 'column', crossAxisAlignment: 'stretch', children: [
        // Search header
        { type: 'padding', padding: [16, 12, 16, 12], child: {
          type: 'row', crossAxisAlignment: 'center', children: [
            selected !== null || form
              ? navButton('arrow_back', 'back_list')
              : { type: 'sizedBox', width: 0 },
            { type: 'expanded', child: {
              type: 'textField', hint: 'Search contacts…', value: query,
              onChange: 'search_change', onSubmit: 'search_submit' } },
            { type: 'sizedBox', width: 10 },
            navButton('add', 'add_open'),
          ] } },
        { type: 'divider', color: t.border, height: 1 },
        noticeLine(),
        body(),
      ],
    });
    jsr.exportState({
      query: query,
      loading: loading,
      resultCount: results.length,
      contacts: results.map(function(c) { return c.name; }),
      selected: selected !== null ? (results[selected] || {}).name : null,
      error: error ? error.message : null,
      form: form ? 'add' : null,
      notice: notice,
    });
  }

  function saveForm() {
    var name = (form.name || '').replace(/^\s+|\s+$/g, '');
    if (!name) { notice = 'Name is required.'; render(); return; }
    var args = { name: name };
    var phone = (form.phone || '').replace(/^\s+|\s+$/g, '');
    var email = (form.email || '').replace(/^\s+|\s+$/g, '');
    if (phone) args.phones = [phone];
    if (email) args.emails = [email];
    jsr.fa.contacts.create(args).then(function(result) {
      if (result && result.__error) {
        notice = String(result.__error);
        render();
      } else {
        notice = 'Contact added.';
        form = null;
        search();
      }
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function doCall() {
    var contact = results[selected];
    if (!contact || !contact.phones || !contact.phones.length) {
      notice = 'This contact has no phone number.';
      render();
      return;
    }
    jsr.fa.contacts.call({ phone: contact.phones[0] }).then(function(result) {
      notice = result && result.__error
        ? String(result.__error)
        : 'Calling ' + contact.name + '…';
      render();
    }, function(e) {
      notice = String(e);
      render();
    });
  }

  function doSms() {
    var contact = results[selected];
    if (!contact || !contact.phones || !contact.phones.length) {
      notice = 'This contact has no phone number.';
      render();
      return;
    }
    var text = (smsText || '').replace(/^\s+|\s+$/g, '');
    if (!text) { notice = 'Type a message first.'; render(); return; }
    jsr.fa.contacts.sms({ phone: contact.phones[0], text: text })
      .then(function(result) {
        if (result && result.__error) {
          notice = String(result.__error);
        } else {
          notice = 'Opening Messages…';
          smsOpen = false;
          smsText = '';
        }
        render();
      }, function(e) {
        notice = String(e);
        render();
      });
  }

  function handleEvent(actionId, payload) {
    if (actionId === 'search_change') {
      query = (payload && payload.value) || '';
      search();
    } else if (actionId === 'search_submit') {
      search();
    } else if (actionId === 'retry') {
      search();
    } else if (actionId === 'back_list') {
      selected = null;
      form = null;
      smsOpen = false;
      render();
    } else if (actionId.indexOf('contact_') === 0) {
      selected = parseInt(actionId.slice(8), 10);
      smsOpen = false;
      smsText = '';
      notice = null;
      render();
    } else if (actionId === 'call') {
      doCall();
    } else if (actionId === 'sms_open') {
      smsOpen = !smsOpen;
      render();
    } else if (actionId === 'sms_change') {
      smsText = (payload && payload.value) || '';
    } else if (actionId === 'sms_send') {
      if (payload && typeof payload.value === 'string') smsText = payload.value;
      doSms();
    } else if (actionId === 'add_open') {
      form = { name: '', phone: '', email: '' };
      selected = null;
      notice = null;
      render();
    } else if (actionId === 'form_name') {
      if (form) form.name = payload && payload.value;
    } else if (actionId === 'form_phone') {
      if (form) form.phone = payload && payload.value;
    } else if (actionId === 'form_email') {
      if (form) form.email = payload && payload.value;
    } else if (actionId === 'form_save') {
      if (form) saveForm();
    } else if (actionId === 'form_cancel') {
      form = null;
      render();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Contacts');
  search();
})();
