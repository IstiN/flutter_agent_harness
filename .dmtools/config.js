// Machine loop wiring for THIS repository (see dmtools-agents
// docs/machine-factory-integration.md §5a). The factory resolves leg →
// runner here; runner paths are repo-relative. bug/story may share a
// single 'dev' entry instead of two.
module.exports = {
  // #687: whose login is "the machine" — see dmtools-agents
  // js/common/machineAuthor.js (jobParams override wins over this).
  machineAuthor: 'vabhzw17eg2qu4m9-bit',
  sm: {
    runners: {
      bug: '.dmtools/runners/fa-bug-dev.json',
      story: '.dmtools/runners/fa-story-dev.json',
      review: '.dmtools/runners/fa-review-kimi.json',
      rework: '.dmtools/runners/fa-rework-zai.json'
    }
  }
};
