describe('nano imported features', function() {

    before(function() {
        require('./init.js');
    });

    require('jugglingdb/test/datatype.test.js');
    require('jugglingdb/test/basic-querying.test.js');
    // require('jugglingdb/test/hooks.test.js');
    require('./hooks.test.js'); // copied from core, added _rev
    require('jugglingdb/test/relations.test.js');
    // require('jugglingdb/test/include.test.js');

});