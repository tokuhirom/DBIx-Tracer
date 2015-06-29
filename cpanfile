requires 'DBI';
requires 'parent';

on test => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Requires';
};
