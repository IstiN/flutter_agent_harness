// IndexedDB persistence helper for the Fa web sandbox (loaded as a plain
// file: MV3 extension pages forbid inline scripts, see fs_persistence_web.dart).
//
// The store is a flat string->string record map, NOT one blob (issue #237):
// the sandbox envelope rides one key and every session file its own record,
// so an oversized or torn write damages one record instead of the whole
// history.
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
window.__fahFsGetAll = function() {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readonly');
      var store = txn.objectStore('snapshots');
      var keysReq = store.getAllKeys();
      var valsReq = store.getAll();
      txn.oncomplete = function() {
        var out = {};
        var keys = keysReq.result;
        var vals = valsReq.result;
        for (var i = 0; i < keys.length; i++) out[keys[i]] = vals[i];
        resolve(out);
      };
      txn.onerror = function() { reject(txn.error); };
      txn.onabort = function() { reject(txn.error); };
    });
  });
};
window.__fahFsSet = function(items) {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      var store = txn.objectStore('snapshots');
      Object.keys(items).forEach(function(key) {
        store.put(items[key], key);
      });
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
      txn.onabort = function() { reject(txn.error); };
    });
  });
};
window.__fahFsRemove = function(keys) {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      var store = txn.objectStore('snapshots');
      keys.forEach(function(key) { store['delete'](key); });
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
      txn.onabort = function() { reject(txn.error); };
    });
  });
};
