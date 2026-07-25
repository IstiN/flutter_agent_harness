// Voice Notes widget — microphone capture + speech-to-text via the
// jsr.fa.asr bridge. Record button → transcript appended to a persisted
// list (jsr.storage). Permission-aware error states like the calendar demo.
(function() {
  var t = jsr.theme;
  var notes = []; // [{ text, seconds, createdMs }]
  var busy = null; // null | 'recording' | 'transcribing'
  var error = null; // null | { kind: 'permission'|'error', message }
  var recordSeconds = 5; // override via jsr.storage 'recordSeconds'

  function fail(msg) {
    busy = null;
    error = {
      kind: msg.indexOf('permission') >= 0 ? 'permission' : 'error',
      message: msg,
    };
  }

  function persist() {
    jsr.storage.set('notes', notes);
  }

  function recordAndTranscribe() {
    if (busy) return;
    busy = 'recording';
    error = null;
    render();
    jsr.fa.asr.record({ seconds: recordSeconds }).then(function(rec) {
      if (rec && rec.__error) {
        fail(String(rec.__error));
        render();
        return;
      }
      busy = 'transcribing';
      render();
      jsr.fa.asr.transcribe({ path: rec.path }).then(function(result) {
        if (result && result.__error) {
          fail(String(result.__error));
        } else {
          busy = null;
          var text = (result && result.text) || '';
          if (text) {
            notes.unshift({
              text: text,
              seconds: Math.round((rec.durationMs || 0) / 1000),
              createdMs: Date.now(),
            });
            persist();
          } else {
            error = { kind: 'error', message: 'The transcript came back empty.' };
          }
        }
        render();
      }, function(e) {
        fail(String(e));
        render();
      });
    }, function(e) {
      fail(String(e));
      render();
    });
  }

  function fmtTime(ms) {
    var d = new Date(ms);
    var h = ('0' + d.getHours()).slice(-2);
    var m = ('0' + d.getMinutes()).slice(-2);
    return h + ':' + m;
  }

  function noteRow(note) {
    return {
      type: 'container',
      margin: [16, 0, 16, 8],
      padding: [12, 12, 12, 12],
      decoration: {
        color: t.surface, borderRadius: 12,
        border: { color: t.border, width: 1 },
      },
      child: { type: 'row', crossAxisAlignment: 'start', children: [
        { type: 'container',
          width: 4, height: 40,
          margin: [0, 0, 10, 0],
          decoration: { color: t.accent, borderRadius: 2 },
        },
        { type: 'expanded', child: {
          type: 'column', crossAxisAlignment: 'start', children: [
            { type: 'text', data: note.text,
              style: { color: t.text, fontSize: 14 } },
            { type: 'sizedBox', height: 4 },
            { type: 'text',
              data: fmtTime(note.createdMs) + '  ·  ' + note.seconds + ' s',
              style: { color: t.muted, fontSize: 11 } },
          ] } },
      ] },
    };
  }

  function recordCard() {
    var isRecording = busy === 'recording';
    var isBusy = busy !== null;
    return {
      type: 'padding', padding: [16, 16, 16, 12], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: isRecording ? '#ef4444' : t.border, width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'mic',
            color: isRecording ? '#ef4444' : t.accent, size: 36 },
          { type: 'sizedBox', height: 8 },
          { type: 'text',
            data: isRecording
              ? 'Recording ' + recordSeconds + ' s…'
              : busy === 'transcribing'
                ? 'Transcribing…'
                : 'Tap to record a ' + recordSeconds + ' s note',
            style: { color: t.text, fontSize: 14, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 10 },
          isBusy
            ? { type: 'circularProgressIndicator', size: 22 }
            : { type: 'button', label: 'Record', onPressed: 'record_toggle',
                color: t.accent },
        ] },
      },
    };
  }

  function errorCard() {
    var isPerm = error.kind === 'permission';
    return {
      type: 'padding', padding: [16, 0, 16, 12], child: {
        type: 'container',
        padding: [16, 16, 16, 16],
        decoration: {
          color: t.surface, borderRadius: 12,
          border: { color: isPerm ? t.accent : '#ef4444', width: 1 },
        },
        child: { type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: isPerm ? 'lock' : 'warning',
            color: isPerm ? t.accent : '#ef4444', size: 28 },
          { type: 'sizedBox', height: 8 },
          { type: 'text',
            data: isPerm ? 'Microphone permission needed' : 'Could not record',
            style: { color: t.text, fontSize: 14, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 6 },
          { type: 'text',
            data: isPerm
              ? 'Grant the microphone permission: tap the shield icon in ' +
                'this app\'s header and enable "Microphone".'
              : error.message,
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
          { type: 'sizedBox', height: 10 },
          { type: 'button', label: 'Retry', onPressed: 'retry',
            color: t.accent },
        ] },
      },
    };
  }

  function emptyState() {
    return {
      type: 'padding', padding: [16, 40, 16, 24], child: {
        type: 'column', crossAxisAlignment: 'center', children: [
          { type: 'icon', name: 'mic_none', color: t.muted, size: 40 },
          { type: 'sizedBox', height: 10 },
          { type: 'text', data: 'No voice notes yet',
            style: { color: t.text, fontSize: 15, fontWeight: 'w600',
              textAlign: 'center' } },
          { type: 'sizedBox', height: 4 },
          { type: 'text', data: 'Record a take — its transcript lands here.',
            style: { color: t.muted, fontSize: 12, textAlign: 'center' } },
        ] },
    };
  }

  function render() {
    jsr.render({
      type: 'column', crossAxisAlignment: 'stretch', children: [
        recordCard(),
        error ? errorCard() : { type: 'sizedBox', height: 0 },
        notes.length
          ? { type: 'padding', padding: [16, 0, 16, 4], child: {
              type: 'row', mainAxisAlignment: 'spaceBetween',
              crossAxisAlignment: 'center', children: [
                { type: 'text',
                  data: notes.length + (notes.length === 1 ? ' note' : ' notes'),
                  style: { color: t.muted, fontSize: 11 } },
                { type: 'textButton', text: 'Clear all', onTap: 'clear_notes' },
              ] } }
          : { type: 'sizedBox', height: 0 },
        notes.length
          ? { type: 'column', crossAxisAlignment: 'stretch',
              children: notes.map(noteRow) }
          : emptyState(),
      ],
    });
    jsr.exportState({
      noteCount: notes.length,
      notes: notes.map(function(n) { return n.text; }),
      busy: busy,
      error: error ? error.message : null,
      recordSeconds: recordSeconds,
    });
  }

  function handleEvent(actionId) {
    if (actionId === 'record_toggle') {
      recordAndTranscribe();
    } else if (actionId === 'retry') {
      error = null;
      render();
    } else if (actionId === 'clear_notes') {
      notes = [];
      persist();
      render();
    }
  }

  jsr.onEvent(handleEvent);
  jsr.onThemeChange(function(theme) { t = theme; render(); });
  jsr.setTitle('Voice Notes');

  // Restore saved notes (and the test/record duration override), then boot.
  jsr.storage.get('recordSeconds').then(function(saved) {
    if (typeof saved === 'number' && saved >= 1 && saved <= 120) {
      recordSeconds = saved;
    }
    jsr.storage.get('notes').then(function(savedNotes) {
      if (savedNotes && savedNotes.length) notes = savedNotes;
      render();
    });
  });
})();
