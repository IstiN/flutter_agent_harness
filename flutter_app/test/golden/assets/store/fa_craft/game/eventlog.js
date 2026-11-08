// Append-only world event log (multiplayer seam, I3): world state is
// seed + ops; every mutation goes through here so a future transport card
// replays the same log instead of rewriting the sim.
var Facraft = Facraft || {};
Facraft.eventlog = {
  create: function() {
    return {
      ops: [],
      _seq: 0,
      append: function(op) {
        op.seq = ++this._seq;
        this.ops.push(op);
        return op;
      },
    };
  },
};
