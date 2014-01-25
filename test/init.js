module.exports = require('should');

var Schema = require('jugglingdb').Schema;

//  Report pending tests when failing as in the past the adapter has had issues with infinite loops.
require('mocha-unfunk-reporter').option('reportPending', true);

global.getSchema = function() {

    var db = new Schema(__dirname + '/..', {
        url: 'http://localhost:5984/nano-test'
    });
    db.log = function (a) { console.log(a); };

    return db;
};
