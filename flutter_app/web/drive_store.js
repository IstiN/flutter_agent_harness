// Provider-neutral drive outbox/snapshot persistence (issue #2364).
// The database is separate from the sandbox FS records: drive metadata must
// never be replayed as sandbox files. Stock Fa never opens this store unless
// a host explicitly constructs the cloud engine.
window.__fahDriveOpen = function() {
  if (!window.__fahDriveDbPromise) {
    window.__fahDriveDbPromise = new Promise(function(resolve, reject) {
      var req = indexedDB.open(window.__fahFsDatabaseName() + ':drive', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('snapshots')) {
          db.createObjectStore('snapshots');
        }
      };
      req.onsuccess = function() { resolve(req.result); };
      req.onerror = function() {
        window.__fahDriveDbPromise = null;
        reject(req.error);
      };
    });
  }
  return window.__fahDriveDbPromise;
};
window.__fahDriveLoad = function(scopeKey) {
  return window.__fahDriveOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readonly');
      var req = txn.objectStore('snapshots').get(scopeKey);
      req.onsuccess = function() { resolve(req.result || null); };
      req.onerror = function() { reject(req.error); };
      txn.onabort = function() { reject(txn.error); };
    });
  });
};
window.__fahDriveSave = function(scopeKey, expectedRevision, payloadJson) {
  return window.__fahDriveOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      var store = txn.objectStore('snapshots');
      var req = store.get(scopeKey);
      req.onsuccess = function() {
        var current = req.result ? req.result.storageRevision : 0;
        if (current !== expectedRevision) {
          reject({name: 'DriveStoreConcurrency', current: current});
          txn.abort();
          return;
        }
        var record = {
          storageRevision: expectedRevision + 1,
          payloadJson: payloadJson
        };
        store.put(record, scopeKey);
        txn.oncomplete = function() { resolve(record); };
      };
      req.onerror = function() { reject(req.error); };
      txn.onerror = function() { reject(txn.error); };
      txn.onabort = function() {
        reject({name: 'DriveStoreConcurrency', current: 'transaction aborted'});
      };
    });
  });
};
