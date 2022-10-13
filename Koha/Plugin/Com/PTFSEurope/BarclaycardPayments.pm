use utf8;

package Koha::Plugin::Com::PTFSEurope::BarclaycardPayments;

=head1 NAME

Koha::Plugin::Com::PTFSEurope::BarclaycardPayments

=cut

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## Koha libraries
use C4::Context;
use C4::Output qw( output_html_with_http_headers );

use C4::Circulation;
use C4::Auth qw( get_template_and_user );

use Koha;

use Koha::Account;
use Koha::Account::Lines;
use Koha::Patrons;

use Mojo::Util qw(b64_decode);
use Digest::SHA qw(sha512_hex);
use File::Basename;
use Data::GUID;
use Data::Dumper;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Barclaycard ePDQ Plugin',
    author          => 'Martin Renvoize',
    date_authored   => '2020-03-01',
    date_updated    => "2022-09-10",
    minimum_version => '20.11.00.000',
    #    maximum_version => '21.11.14.000',
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'Barclaycard ePDQ payments platform.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

=head2 opac_online_payment_begin

  Initiate online payment process

=cut

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi    = $self->{'cgi'};
    my $schema = Koha::Database->new()->schema();

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Construct form
    my $inputs;

    # Minimum fields
    # PSPID, ORDERID, AMOUNT, CURRENCY (ISO 4217),
    # LANGUAGE (ISO 639-1 + ISO 3166-1), SHASIGN

    # Credentials
    $inputs->{PSPID} = $self->retrieve_data('PSPID');

    # Transaction details
    my $ORDERID = Data::GUID->new->as_string;
    $inputs->{ORDERID} = $ORDERID;

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('orders');
    my $sth =
      $dbh->prepare(
"INSERT INTO $table (`orderid`, `accountline_id`, `amount`) VALUES (?, ?, ?)"
      );

    my $sum_amountInMinorUnits = 0;
    my @accountline_ids        = $cgi->multi_param('accountline');
    my $accountlines           = $schema->resultset('Accountline')
      ->search( { accountlines_id => \@accountline_ids } );
    for my $accountline ( $accountlines->all ) {
        my $amount = sprintf "%.2f", $accountline->amountoutstanding;
        $amount                 = $amount * 100;
        $sum_amountInMinorUnits = $sum_amountInMinorUnits + $amount;
        $sth->execute( $ORDERID, $accountline->accountlines_id, $amount );
    }
    $inputs->{AMOUNT}   = $sum_amountInMinorUnits;
    $inputs->{CURRENCY} = 'GBP';

    # User
    my $borrower = Koha::Patrons->find($borrowernumber);

    #$input->{LANGUAGE} = $ISO639 . "_" . $ISO3166;
    $inputs->{LANGUAGE} = 'en_US';

    # Recommended fields
    # EMAIL, OWNERADDRESS, OWNERZIP, OWNERTOWN, OWNERCTY, OWNERTELNO
    $inputs->{EMAIL}        = $borrower->first_valid_email_address;
    $inputs->{OWNERADDRESS} = $borrower->address;
    $inputs->{OWNERZIP}     = $borrower->zipcode;
    $inputs->{OWNERTOWN}    = $borrower->city;
    $inputs->{OWNERTELNO}   = $borrower->phone;

    # Optional fields
    # USERID, ACCEPTURL, DECLINEURL, EXCEPTIONURL, CANCELURL, BACKURL
    $inputs->{USERID} = $borrower->borrowernumber;

    # Return URI fields
    my $returnURL = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl" );

    $returnURL->query_form(
        {
            payment_method => scalar $cgi->param('payment_method')
        }
    );
    $inputs->{ACCEPTURL}  = $returnURL->as_string;
    $inputs->{DECLINEURL} = $returnURL->as_string;
    $inputs->{CANCELURL}  = $returnURL->as_string;

    my $backURL = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account.pl" );
    $inputs->{BACKURL} = $backURL->as_string;

    # Signature
    my $SHASIGN = $self->get_digest($inputs);
    $inputs->{SHASIGN} = $SHASIGN;

    my $portal = $self->get_url;
    $template->param(
        paymentPortal => $portal,
        inputs        => $inputs
    );

    $self->output_html( $template->output() );
}

=head2 opac_online_payment_end

  Complete online payment process

=cut

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $ORDERID = $cgi->param('ORDERID');
    my $STATUS  = $cgi->param('STATUS');
    my $NCERROR = $cgi->param('NCERROR');
    my $PAYID   = $cgi->param('PAYID');
    my $error   = 0;

    my $table = $self->get_qualified_table_name('orders');
    my $dbh   = C4::Context->dbh;
    my $sth =
      $dbh->prepare(
        "SELECT accountline_id, amount FROM $table WHERE orderid = ?");
    $sth->execute($ORDERID);
    my @accountlines;
    my $total_amount = 0;

    while ( my ( $accountline_id, $amount ) = $sth->fetchrow_array() ) {
        push @accountlines, $accountline_id;
        $total_amount = $total_amount + $amount;
    }
    $total_amount = $total_amount / 100;

    # Success
    if ( $STATUS == 5 || $STATUS == 9 ) {
        my $account = Koha::Account->new( { patron_id => $borrowernumber } );
        my @lines   = Koha::Account::Lines->search(
            {
                accountlines_id => { -in => \@accountlines }
            }
        );

        $account->pay(
            {
                amount    => $total_amount,
                lines     => \@lines,
                note      => 'BarclaycardPayments',
                interface => C4::Context->interface
            }
        );
        print $cgi->redirect("/cgi-bin/koha/opac-account.pl?payment=$total_amount");
    }

    # Failed
    elsif ( $STATUS == 2 ) {
        $template->param( error_code => "ERROR_FAILED" );
        $error = 1;
    }

    # Cancelled
    elsif ( $STATUS == 1 ) {
        $template->param( error_code => "ERROR_CANCELLED" );
        $error = 1;
    }
    else {
        $template->param( error_code => "ERROR_PROCESSING" );
        $error = 1;
    }

    output_html_with_http_headers( $cgi, $cookie, $template->output, undef,
        { force_no_caching => 1 } )
      if $error;
}

=head2 configure

  Configuration routine
  
=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            TestMode  => $self->retrieve_data('TestMode'),
            PSPID     => $self->retrieve_data('PSPID'),
            'SHA_IN'  => $self->retrieve_data('SHA_IN'),
            'SHA_OUT' => $self->retrieve_data('SHA_OUT')
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                TestMode             => $cgi->param('TestMode'),
                PSPID                => $cgi->param('PSPID'),
                'SHA_IN'             => $cgi->param('SHA_IN'),
                'SHA_OUT'            => $cgi->param('SHA_OUT'),
                last_configured_by   => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('orders');

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `orderid` varchar(36) NOT NULL,
            `accountline_id` INT( 11 ),
            `amount` INT( 11 )
        ) ENGINE = INNODB;
    " );
}

=head2 get_digest

  Internal routine for generating the signature digest for messages

=cut

sub get_digest {
    my $self   = shift;
    my $params = shift;

    my $SHA_IN = $self->retrieve_data('SHA_IN');

    my $data;
    for my $param ( sort keys %{$params} ) {
        $data .= uc($param) . '=' . $params->{$param} . $SHA_IN
          if ( defined( $params->{$param} ) && $params->{$param} ne '' );
    }

    # FIXME: Test this works "naturally" with ITEM1, ITEM2, ITEM10, ITEM11

    my $digest = sha512_hex($data);
    while ( length($digest) % 4 ) {
        $digest .= '=';
    }

    warn "Data to hash: " . $data;
    warn "Digest: " . uc($digest);

    return uc($digest);
}

sub validate_digest {
    my ( $self, $params ) = @_;

    my $SHA_OUT = $self->retrieve_data('SHA_OUT');

    my $data;
    for my $param ( sort keys %{$params} ) {
        unless ( $param eq 'SHASIGN' ) {
            $data .= uc($param) . '=' . $params->{$param} . $SHA_OUT
              if ( defined( $params->{$param} ) && $params->{$param} ne '' );
        }
    }

}

=head2 get_url

  Internal method to return the current url for to post payments to

=cut

sub get_url {
    my $self = shift;

    my $test_mode = $self->retrieve_data('TestMode') // 1;

    return $test_mode
      ? 'https://mdepayments.epdq.co.uk/ncol/test/orderstandard_utf8.asp'
      : 'https://payments.epdq.co.uk/ncol/prod/orderstandard_utf8.asp';
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
#sub upgrade {
#    my ( $self, $args ) = @_;
#
#    my $dt = dt_from_string();
#    $self->store_data(
#        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );
#
#    return 1;
#}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
#sub uninstall() {
#    my ( $self, $args ) = @_;
#
#    my $table = $self->get_qualified_table_name('mytable');
#
#    return C4::Context->dbh->do("DROP TABLE $table");
#}

sub _version_check {
    my ( $self, $minversion ) = @_;

    $minversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    my $kohaversion = Koha::version();

    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;

    return ( $kohaversion > $minversion );
}

1;
