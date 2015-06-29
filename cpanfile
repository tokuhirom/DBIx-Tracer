requires 'DBI';
requires 'parent';

on build => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Requires';
};
