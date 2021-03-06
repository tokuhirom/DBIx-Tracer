use strict;
use warnings;
use Test::Requires qw(DBD::mysql Test::mysqld);
use Test::More;
use Test::mysqld;
use t::Util;
use DBIx::Tracer ();
use DBI;

my $mysqld = t::Util->setup_mysqld
    or plan skip_all => $Test::mysqld::errstr || 'failed setup_mysqld';

my $dbh = DBI->connect(
    $mysqld->dsn(dbname => 'mysql'), '', '',
    {
        AutoCommit => 1,
        RaiseError => 1,
    },
) or die $DBI::errstr;

{
    my @res = capture {
        $dbh->selectrow_hashref(
            'SELECT * FROM user WHERE User = ? LIMIT ? OFFSET ?',
            undef,
            'root', 1, 0,
        );
    };

    is 0+@res, 1;
    is $res[0]->{sql}, 'SELECT * FROM user WHERE User = ? LIMIT ? OFFSET ?';
    is_deeply $res[0]->{bind_params}, ['root', 1, 0];
}

{
    my @res = capture {
        $dbh->selectrow_arrayref(
            'SELECT * FROM (SELECT * FROM user WHERE User = ? LIMIT ?) AS user WHERE User = ? LIMIT ? OFFSET ?',
            undef,
            'root', 1, 'root', 1, 0,
        );
    };

    is 0+@res, 1;
    is $res[0]->{sql}, 'SELECT * FROM (SELECT * FROM user WHERE User = ? LIMIT ?) AS user WHERE User = ? LIMIT ? OFFSET ?';
    is_deeply $res[0]->{bind_params}, ['root', 1, 'root', 1, 0];
}

done_testing;
