// Account-scoped cloud-session outbox CAS. Kept in a separate IndexedDB
// database so JSONL sync metadata never mixes with drive or sandbox records.
window.__fahCloudSessionOpen = function() {
  if (!window.__fahCloudSessionDbPromise) {
    window.__fahCloudSessionDbPromise = new Promise(function(resolve, reject) {
      var req = indexedDB.open(window.__fahFsDatabaseName() + ':sessions', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('snapshots')) {
          db.createObjectStore('snapshots');
        }
      };
      req.onsuccess = function() { resolve(req.result); };
      req.onerror = function() {
        window.__fahCloudSessionDbPromise = null;
        reject(req.error);
      };
    });
  }
  return window.__fahCloudSessionDbPromise;
};
window.__fahCloudSessionLoad = function(scopeKey) {
  return window.__fahCloudSessionOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readonly');
      var req = txn.objectStore('snapshots').get(scopeKey);
      req.onsuccess = function() { resolve(req.result || null); };
      req.onerror = function() { reject(req.error); };
      txn.onabort = function() { reject(txn.error); };
    });
  });
};
window.__fahCloudSessionSave = function(scopeKey, expectedRevision, payloadJson) {
  return window.__fahCloudSessionOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      var store = txn.objectStore('snapshots');
      var req = store.get(scopeKey);
      req.onsuccess = function() {
        var current = req.result ? req.result.storageRevision : 0;
        if (current !== expectedRevision) {
          reject({name: 'CloudSessionStoreConcurrency', current: current});
          txn.abort();
          return;
        }
        var record = {storageRevision: expectedRevision + 1, payloadJson: payloadJson};
        store.put(record, scopeKey);
        txn.oncomplete = function() { resolve(record); };
      };
      req.onerror = function() { reject(req.error); };
      txn.onerror = function() { reject(txn.error); };
      txn.onabort = function() {
        reject({name: 'CloudSessionStoreConcurrency', current: 'transaction aborted'});
      };
    });
  });
};
