package Store::CouchDB;

use Any::Moose;
use JSON;
use LWP::UserAgent;
use URI::Escape;

=head1 NAME

Store::CouchDB - a simple CouchDB driver

=head1 VERSION

Version 2.6.6

=cut

=head1 SYNOPSIS

Store::CouchDB is a very thin wrapper around CouchDB. It is essentially
a set of calls I use in production and is by no means a complete
library, it is just complete enough for the things I need to do. This is
a grown set of functions that evolved over the last years of using
CouchDB in various projects and was written originally to be compatible
with DB::CouchDB. This has long passed and can only be noticed at some
places.

One of the things I banged my head against for some time is non UTF8
stuff that somehow enters the system and then breaks CouchDB. I use the
brilliant Encoding::FixLatin module to fix this on the fly.

    use Store::CouchDB;

    my $db = Store::CouchDB->new();
    $db->config({host => 'localhost', db => 'your_db'});
    my $couch = {
        view   => 'design_doc/view',
        opts   => { key => '"' . $key . '"' },
    };
    my $status = $db->get_array_view($couch);

=cut

our $VERSION = '2.6';

has 'debug' => (
    is      => 'rw',
    isa     => 'Bool',
    default => sub { 0 },
    lazy    => 1,
);

has 'host' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
    default  => sub { 'localhost' });

has 'port' => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => sub { 5984 });

has 'ssl' => (
    is      => 'rw',
    isa     => 'Bool',
    default => sub { 0 },
    lazy    => 1,
);

has 'db' => (
    is        => 'rw',
    isa       => 'Str',
    required  => 1,
    lazy      => 1,
    default   => sub { },
    predicate => 'has_db',
);

has 'user' => (
    is  => 'rw',
    isa => 'Str',
);

has 'pass' => (
    is  => 'rw',
    isa => 'Str',
);

has 'method' => (
    is       => 'rw',
    required => 1,
    default  => sub { 'GET' });

has 'error' => (
    is        => 'rw',
    predicate => 'has_error',
    clearer   => 'clear_error',
);

has 'purge_limit' => (
    is      => 'rw',
    default => sub { 5000 });

has 'timeout' => (
    is      => 'rw',
    isa     => 'Int',
    default => sub { 30 },
);

has 'json' => (
    is      => 'rw',
    isa     => 'JSON',
    default => sub {
        JSON->new->utf8->allow_nonref->allow_blessed->convert_blessed;
    },
);

=head1 FUNCTIONS

=head2 new

The Store::CouchDB class takes a number of parameters:

=head3 debug

Sets the class in debug mode

=head3 host

The host to use. Defaults to 'localhost'

=head3 port

The port to use. Defaults to '5984'

=head4 ssl

Connect to host via SSL/TLS. Defaults to '0'

=head3 db

The DB to use. This has to be set for all oprations!

=head3 user

The DB user to authenticate as. optional

=head3 pass

The password for the user to authenticate with. required if user is given.

=head3 method

This is internal and sets the request method to be used (GET|POST)

=head3 error

This is set if an error has occured and can be called to get the last
error with the 'has_error' predicate.

    $db->has_error

=head3 purge_limit

How many documents shall we try to purge. Defaults to 5000

=head2 get_doc

The get_doc call returns a document by its ID

    get_doc({id => DOCUMENT_ID, [dbname => DATABASE]})

=cut

sub get_doc {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;
    confess "Document ID not defined" unless $data->{id};

    my $path = $self->db . '/' . $data->{id};
    return $self->_call($path);
}

=head2 head_doc

If all you need is the revision a HEAD call is enough.

=cut

sub head_doc {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;
    confess "Document ID not defined" unless $data->{id};
    $self->method('HEAD');

    my $path = $self->db . '/' . $data->{id};
    my $rev  = $self->_call($path);
    $rev =~ s/"//g;
    return $rev;
}

=head2 get_design_docs

The get_design_docs call returns all design document names in an array
reference.

    get_design_docs({[dbname => DATABASE]})

=cut

sub get_design_docs {
    my ($self, $data) = @_;

    if ($data && $data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path = $self->db
        . '/_all_docs?descending=true&startkey="_design0"&endkey="_design"';
    $self->method('GET');
    my $res = $self->_call($path);
    return unless $res->{rows}->[0];
    my @design;
    foreach my $_design (@{ $res->{rows} }) {
        my ($_d, $name) = split(/\//, $_design->{key}, 2);
        push(@design, $name);
    }
    return \@design;
}

=head2 put_doc

The put_doc call writes a document to the database and either updates a
existing document if the _id field is present or writes a new one.
Updates can also be done with the update_doc call but that is really
just a wrapper for put_doc.

    put_doc({doc => DOCUMENT, [dbname => DATABASE]})

=cut

sub put_doc {
    my ($self, $data) = @_;

    confess "Document not defined" unless $data->{doc};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path;
    my $method = $self->method();
    if ($data->{doc}->{_id}) {
        $self->method('PUT');
        $path = $self->db . '/' . $data->{doc}->{_id};
        delete $data->{doc}->{_id};
    }
    else {
        $self->method('POST');
        $path = $self->db;
    }

    my $res = $self->_call($path, $data->{doc});
    $self->method($method);

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{id} || undef;
}

=head2 del_doc

The del_doc call marks a document as deleted. CouchDB needs a revision
to delete a document which is good for security but is not practical for
me in some situations. If no revision is supplied del_doc will get the
document, find the latest revision and delete the document.

    del_doc({id => DOCUMENT_ID, [rev => REVISION, dbname => DATABASE]})

=cut

sub del_doc {
    my ($self, $data) = @_;

    my $id  = $data->{id}  || $data->{_id};
    my $rev = $data->{rev} || $data->{_rev};

    confess "Document ID not defined" unless $id;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    if (!$rev) {
        $rev = $self->head_doc({ id => $id });
    }

    my $path;
    $self->method('DELETE');
    $path = $self->db . '/' . $id . '?rev=' . $rev;
    my $res = $self->_call($path);
    $self->method('GET');

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{rev} || undef;
}

=head2 update_doc

The update_doc function is really just a wrapper for the put_doc call
and mainly there for compatibility. the naming is different and it is
discouraged to use and may disappear in a later version.

    update_doc({doc => DOCUMENT, [name => DOCUMENT_ID, dbname => DATABASE]})

=cut

sub update_doc {
    my ($self, $data) = @_;

    confess "Document not defined" unless $data->{doc};

    if ($data->{name}) {
        $data->{doc}->{_id} = $data->{name};
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    return $self->put_doc($data);
}

=head2 copy_doc

The copy_doc is _not_ the same as the CouchDB equivalent. In CouchDB the
copy command wants to have a name/id for the new document which is
mandatory and can not be ommitted. I find that inconvenient and made
this small wrapper. All it does is getting the doc to copy, removes the
_id and _rev fields and saves it back as a new document.

    copy_doc({id => DOCUMENT_ID, [dbname => DATABASE]})

=cut

sub copy_doc {
    my ($self, $data) = @_;

    confess "Document ID not defined" unless $data->{id};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    # as long as CouchDB does not support automatic document name creation
    # for the copy command we copy the ugly way ...
    my $doc = $self->get_doc($data);
    delete $doc->{_id};
    delete $doc->{_rev};
    return $self->put_doc({ doc => $doc });
}

=head2 get_view

There are several ways to represent the result of a view and various
ways to query for a view. All the views support parameters but there are
different functions for GET/POST view handling and representing the
reults.
The get_view uses GET to call the view and returns a hash with the _id
as the key and the document as a value in the hash structure. This is
handy for getting a hash structure for several documents in the DB.

   get_view(
       {
           view => 'DESIGN_DOC/VIEW',
           opts => { key => "\"" . KEY . "\"" }
       }
   );

=cut

sub get_view {
    my ($self, $data) = @_;

    confess "View not defined" unless $data->{view};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    return unless $res->{rows}->[0];

    my $c      = 0;
    my $result = {};
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            $result->{ $doc->{key} || $c } = $doc->{doc};
        }
        else {
            next unless exists $doc->{value};
            if (ref $doc->{key} eq 'ARRAY') {
                _hash($result, $doc->{value}, @{ $doc->{key} });
            }
            else {
                # TODO debug why this crashes from time to time
                #$doc->{value}->{id} = $doc->{id};
                $result->{ $doc->{key} || $c } = $doc->{value};
            }
        }
        $c++;
    }
    return $result;
}

=head2 get_post_view

The get_post_view uses POST to call the view and returns a hash with the _id
as the key and the document as a value in the hash structure. This is
handy for getting a hash structure for several documents in the DB.

   get_post_view(
       {
           view => 'DESIGN_DOC/VIEW',
           opts => [ KEY1, KEY2, KEY3, ... ]
       }
   );

=cut

sub get_post_view {
    my ($self, $data) = @_;

    confess "View not defined"                            unless $data->{view};
    confess "No options defined - use 'get_view' instead" unless $data->{opts};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $opts;
    if ($data->{opts}) {
        $opts = delete $data->{opts};
    }
    my $path   = $self->_make_view_path($data);
    my $method = $self->method();

    $self->method('POST');
    my $res = $self->_call($path, $opts);
    $self->method($method);

    my $result;
    foreach my $doc (@{ $res->{rows} }) {
        next unless exists $doc->{value};
        $doc->{value}->{id} = $doc->{id};
        $result->{ $doc->{key} } = $doc->{value};
    }

    return $result;
}

=head2 get_view_array

Same as get_array_view only returns a real array. Use either one
depending on your use case and convenience.

=cut

sub get_view_array {
    my ($self, $data) = @_;

    confess "View not defined" unless $data->{view};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);
    my @result;
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            push(@result, $doc->{doc});
        }
        else {
            next unless exists $doc->{value};
            if (ref($doc->{value}) eq 'HASH') {
                $doc->{value}->{id} = $doc->{id};
                push(@result, $doc->{value});
            }
            else {
                push(@result, $doc);
            }
        }
    }
    return \@result;
}

=head2 get_array_view

The get_array_view uses GET to call the view and returns an array
reference of matched documents. This view functions is the one I use
most and has the best support for corner cases.

   get_array_view(
       {
           view => 'DESIGN_DOC/VIEW',
           opts => { key => "\"" . KEY . "\"" }
       }
   );

A normal response hash would be the "value" part of the document with
the _id moved in as "id". If the response is not a HASH (the request was
resulting in key/value pairs) the entire doc is returned resulting in a
hash of key/value/id per document.

=cut

sub get_array_view {
    my ($self, $data) = @_;

    confess "View not defined" unless $data->{view};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    my $result;
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            push(@{$result}, $doc->{doc});
        }
        else {
            next unless exists $doc->{value};
            if (ref($doc->{value}) eq 'HASH') {
                $doc->{value}->{id} = $doc->{id};
                push(@{$result}, $doc->{value});
            }
            else {
                push(@{$result}, $doc);
            }
        }
    }
    return $result;
}

=head2 purge

This function tries to find deleted documents via the _changes call and
then purges as many deleted documents as defined in $self->purge_limit
which currently defaults to 5000. This call is somewhat experimental in
the moment.

    purge({[dbname => DATABASE]})

=cut

sub purge {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $path = $self->db . '/_changes?limit=' . $self->purge_limit . '&since=0';
    $self->method('GET');
    my $res = $self->_call($path);
    return unless $res->{results}->[0];
    my @del;
    $self->method('POST');
    my $resp;

    foreach my $_del (@{ $res->{results} }) {
        next unless ($_del->{deleted} and ($_del->{deleted} eq 'true'));
        my $opts = {

            #purge_seq => $_del->{seq},
            $_del->{id} => [ $_del->{changes}->[0]->{rev} ],
        };
        $resp->{ $_del->{seq} } = $self->_call($self->db . '/_purge', $opts);
    }
    return $resp;
}

=head2 compact

This compacts the DB file and optionally calls purge and cleans up the
view index as well.

    compact({[purge=>1, view_compact=>1]})

=cut

sub compact {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $res;
    if ($data->{purge}) {
        $res->{purge} = $self->purge();
    }
    if ($data->{view_compact}) {
        $self->method('POST');
        $res->{view_compact} = $self->_call($self->db . '/_view_cleanup');
        my $design = $self->get_design_docs();
        $self->method('POST');
        foreach my $doc (@{$design}) {
            $res->{ $doc . '_compact' } =
                $self->_call($self->db . '/_compact/' . $doc);
        }
    }
    $self->method('POST');
    $res->{compact} = $self->_call($self->db . '/_compact');

    return $res;
}

=head2 put_file

To add an attachement to CouchDB use the put_file method. 'file' because
it is shorter than attachement and less prone to misspellings. The
put_file method works like the put_doc function and will add an
attachement to an existing doc if the '_id' parameter is given or addes
a new doc with the attachement if no '_id' parameter is given.
The only mandatory parameter is the 'file' parameter.

=cut

sub put_file {
    my ($self, $data) = @_;

    confess "File content not defined" unless $data->{file};
    confess "File name not defined"    unless $data->{filename};

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;

    my $id  = $data->{id}  || $data->{doc}->{_id};
    my $rev = $data->{rev} || $data->{doc}->{_rev};
    my $method = $self->method();

    if (!$rev and $id) {
        $rev = $self->head_doc({ id => $id });
        print STDERR ">>$rev<<\n";
    }
    ($id, $rev) = $self->put_doc({ doc => {} })
        unless $id;    # create a new doc

    my $path = $self->db . '/' . $id . '/' . $data->{filename} . '?rev=' . $rev;

    $self->method('PUT');
    my $res = $self->_call($path, $data->{file}, $data->{content_type});
    $self->method($method);

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{id} || undef;
}

=head2 get_file

Get a file attachement from a CouchDB document.

=cut

sub get_file {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }
    $self->_check_db;
    confess "Document ID not defined" unless $data->{id};
    confess "File name not defined"   unless $data->{filename};

    my $path = join('/', $self->db, $data->{id}, $data->{filename});
    return $self->_call($path);
}

=head2 config

This can be called with a hash of config values to configure the databse
object. I use it frequently with sections of config files.

    config({[host => HOST, port => PORT, db => DATABASE]})

=cut

sub config {
    my ($self, $data) = @_;

    foreach my $key (keys %{$data}) {
        $self->$key($data->{$key}) or confess "$key not defined as property!";
    }
    return $self;
}

sub _check_db {
    my ($self) = @_;

    confess "database missing! you must set \$self->db() before running queries"
        unless $self->has_db;
}

sub _make_view_path {
    my ($self, $data) = @_;

    my $view = $data->{view};
    $view =~ s/^\///;
    my @view = split(/\//, $view, 2);
    my $path = $self->db . '/_design/' . $view[0] . '/_view/' . $view[1];

    if (keys %{ $data->{opts} }) {
        $path .= '?';
        foreach my $key (keys %{ $data->{opts} }) {
            my $value = $data->{opts}->{$key};
            if ($key =~ m/key/) {
                $value = $self->json->encode($value);
            }
            $value = uri_escape($value);
            $path .= $key . '=' . $value . '&';
        }

        # remove last '&'
        chop($path);
    }

    return $path;
}

sub _call {
    my ($self, $path, $content, $ct) = @_;

    binmode(STDERR, ":utf8");

    # cleanup old error
    $self->clear_error if $self->has_error;

    my $uri = ($self->ssl) ? 'https://' : 'http://';
    $uri .= $self->user . ':' . $self->pass . '@'
        if ($self->user and $self->pass);
    $uri .= $self->host . ':' . $self->port . '/' . $path;
    print STDERR __PACKAGE__ . ": URI: $uri\n" if $self->debug;

    my $req = HTTP::Request->new();
    $req->method($self->method);
    $req->uri($uri);

    $req->content((
              $ct
            ? $content
            : $self->json->encode($content))) if ($content);

    my $ua = LWP::UserAgent->new(timeout => $self->timeout);

    $ua->default_header('Content-Type' => $ct || "application/json");
    my $res = $ua->request($req);
    if ($self->debug) {
        require Data::Dumper;
        print STDERR __PACKAGE__
            . ": Result: "
            . Data::Dumper::Dumper($res->decoded_content);
    }
    if ($self->method eq 'HEAD') {
        if ($self->debug) {
            print STDERR __PACKAGE__
                . ": Revision: "
                . $res->header('ETag') . "\n";
        }
        return $res->header('ETag') || undef;
    }
    elsif ($res->is_success) {
        my $result;
        eval { $result = $self->json->decode($res->content) };
        return $result unless $@;
        return {
            file         => $res->decoded_content,
            content_type => $res->content_type
        };
    }
    else {
        $self->error($res->status_line);
    }
    return;
}

sub _hash {
    my ($head, $val, @tail) = @_;
    if ($#tail == 0) {
        return $head->{ shift(@tail) } = $val;
    }
    else {
        return _hash($head->{ shift(@tail) } //= {}, $val, @tail);
    }
}

=head1 EXPORT

Nothing is exported at this stage.

=head1 AUTHOR

Lenz Gschwendtner, C<< <norbu09 at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-store-couchdb at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Store-CouchDB>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Store::CouchDB


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Store-CouchDB>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Store-CouchDB>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Store-CouchDB>

=item * Search CPAN

L<http://search.cpan.org/dist/Store-CouchDB/>

=back


=head1 ACKNOWLEDGEMENTS

Thanks for DB::CouchDB which was very enspiring for writing this library

=head1 COPYRIGHT & LICENSE

Copyright 2010 Lenz Gschwendtner.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the Apache License or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;    # End of Store::CouchDB
