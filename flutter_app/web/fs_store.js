window.__fahFsOpen = function() {
  if (!window.__fahFsDbPromise) {
    window.__fahFsDbPromise = new Promise(function(resolve, reject) {
      var req = indexedDB.open('fah_web_fs', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('snapshots')) {
          db.createObjectStore('snapshots');
        }
      };
      req.onsuccess = function() { resolve(req.result); };
      req.onerror = function() {
        window.__fahFsDbPromise = null;
        reject(req.error);
      };
    });
  }
  return window.__fahFsDbPromise;
};
// Flat key->value surface (issue #237): the versioned envelope lives under
// one key, every session file is its own record, so an over-quota session
// write fails alone. Values are strings; loadAll returns a JSON map so the
// Dart side needs no JSObject interop.
window.__fahFsLoadAll = function() {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var store = db.transaction('snapshots', 'readonly')
        .objectStore('snapshots');
      var keysReq = store.getAllKeys();
      var valsReq = store.getAll();
      var keys, vals;
      function maybeDone() {
        if (keys === undefined || vals === undefined) return;
        var map = {};
        for (var i = 0; i < keys.length; i++) map[keys[i]] = vals[i];
        resolve(JSON.stringify(map));
      }
      keysReq.onsuccess = function() { keys = keysReq.result; maybeDone(); };
      valsReq.onsuccess = function() { vals = valsReq.result; maybeDone(); };
      keysReq.onerror = function() { reject(keysReq.error); };
      valsReq.onerror = function() { reject(valsReq.error); };
    });
  });
};
window.__fahFsSave = function(key, value) {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      txn.objectStore('snapshots').put(value, key);
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
    });
  });
};
window.__fahFsRemove = function(keysJson) {
  var keys = JSON.parse(keysJson);
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      var store = txn.objectStore('snapshots');
      for (var i = 0; i < keys.length; i++) store.delete(keys[i]);
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
    });
  });
};
