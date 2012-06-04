use strict;
use warnings;
use Test::Requires 'DBD::SQLite';
use Test::More;
use t::Util;
use DBIx::Tracer;

my $dbh = t::Util->new_dbh;

my @logs = capture {
    DBIx::Tracer->enable;
    $dbh->do('SELECT * FROM sqlite_master');
};

like $logs[0]->{sql}, qr/SELECT \* FROM sqlite_master/, 'SQL';

done_testing;
