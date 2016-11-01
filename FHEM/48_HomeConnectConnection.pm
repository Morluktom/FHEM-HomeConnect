=head1
        48_HomeConnectConnection.pm

# $Id: $

        Version 0.1

=head1 SYNOPSIS
        Bosch Siemens Home Connect Modul for FHEM
        contributed by Stefan Willmeroth 09/2016

=head1 DESCRIPTION
        48_HomeConnectConnection keeps the OAuth token needed by devices defined by
        48_HomeConnect 

=head1 AUTHOR - Stefan Willmeroth
        swi@willmeroth.com (forum.fhem.de)
=cut

package main;

use strict;
use warnings;
use JSON;
use URI::Escape;
use Switch;
use Data::Dumper; #debugging
require 'HttpUtils.pm';

##############################################
sub HomeConnectConnection_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}        = "HomeConnectConnection_Set";
  $hash->{DefFn}        = "HomeConnectConnection_Define";
  $hash->{GetFn}        = "HomeConnectConnection_Get";
  $hash->{FW_summaryFn} = "HomeConnectConnection_FwFn";
  $hash->{FW_detailFn}  = "HomeConnectConnection_FwFn";
}

###################################
sub HomeConnectConnection_Set($@)
{
  my ($hash, @a) = @_;
  my $rc = undef;
  my $reDOUBLE = '^(\\d+\\.?\\d{0,2})$';

  my ($gterror, $gotToken) = getKeyValue($hash->{NAME}."_accessToken");

  return "no set value specified" if(int(@a) < 2);
  return "LoginNecessary" if($a[1] eq "?" && !defined($gotToken));
  return "scanDevices refreshToken logout" if($a[1] eq "?");
  if ($a[1] eq "auth") {
    return HomeConnectConnection_GetAuthToken($hash,$a[2]);
  }
  if ($a[1] eq "scanDevices") {
    HomeConnectConnection_AutocreateDevices($hash);
  }
  if ($a[1] eq "refreshToken") {
    undef $hash->{expires_at};
    HomeConnectConnection_RefreshToken($hash);
  }
  if ($a[1] eq "logout") {
    setKeyValue($hash->{NAME}."_accessToken",undef);
    setKeyValue($hash->{NAME}."_refreshToken",undef);
    undef $hash->{expires_at};
    $hash->{STATE} = "Login necessary";
  }
}

#####################################
sub HomeConnectConnection_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $u = "wrong syntax: define <conn-name> HomeConnectConnection [client_id] [redirect_uri] [simulator]";

  return $u if(int(@a) < 4);

  $hash->{api_uri} = "https://api.home-connect.com";

  if(int(@a) >= 4) {
    $hash->{client_id} = $a[2];
    $hash->{redirect_uri} = $a[3];
    if ("simulator" eq $a[4]) {
      $hash->{simulator} = "1";
      $hash->{api_uri} = "https://developer.home-connect.com";
    }
  }
#  else {
#    $hash->{client_id} = "future built-in key";
#    $hash->{redirect_uri} = "http://fhem:8083/fhem?cmd.Test=set%20hcconn%20auth%20";
#  }
  $hash->{STATE} = "Login necessary";

  # start with a delayed token refresh
  setKeyValue($hash->{NAME}."_accessToken",undef);
  undef $hash->{expires_at};
  InternalTimer(gettimeofday()+10, "HomeConnectConnection_RefreshTokenTimer", $hash, 0);

  return;
}

#####################################
sub
HomeConnectConnection_FwFn($$$$)
{
  my ($FW_wname, $d, $room, $pageHash) = @_; # pageHash is set for summaryFn.
  my $hash   = $defs{$d};

  my ($gterror, $authToken) = getKeyValue($hash->{NAME}."_accessToken");

  my $fmtOutput;

  if (defined $authToken) {

    $fmtOutput = $hash->{STATE} = "Logged in";

  } else {

    my $scope = "IdentifyAppliance%20Monitor%20Settings%20Dishwasher-Control%20Washer-Control%20Dryer-Control%20CoffeeMaker-Control";

    $fmtOutput = "<a href=\"$hash->{api_uri}/security/oauth/authorize?response_type=code&" .
	"redirect_uri=". uri_escape($hash->{redirect_uri}) . "&realm=fhem.de&" .
        "client_id=$hash->{client_id}&scope=$scope&".
	"state=HomeConnectConnection_auth\">Home Connect Login</a>";
    $hash->{STATE} = "Login necessary";

  }

  return $fmtOutput;

}

#####################################
sub HomeConnectConnection_GetAuthToken
{
  my ($hash,$tokens) = @_;
  my $name = $hash->{NAME};
  my $JSON = JSON->new->utf8(0)->allow_nonref;

  my $code = $FW_webArgs{"code"};
  if (!defined $code) {
    Log3 $name, 3, "Searching auth tokens in: $tokens";
    $tokens =~ m/code=([^&]*)/;
    $code = $1;
  }

  Log3 $name, 3, "Got oauth code: $code";

  my($err,$data) = HttpUtils_BlockingGet({
    url => "$hash->{api_uri}/security/oauth/token",
    timeout => 10,
    noshutdown => 1,
    data => {grant_type => 'authorization_code', 
	client_id => $hash->{client_id},
	code => $code,
	redirect_uri => $hash->{redirect_uri}
    }
  });

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data ) {
    Log3 $name, 2, "$name: AuthTokenResponse $data";

    $data =~ s/\n//g;
    if( $data !~ m/^{.*}$/m ) {
      Log3 $name, 2, "$name: invalid json detected: >>$data<<";
      return undef;
    }
  }

  my $json = $JSON->decode($data);

  if( $json->{error} ) {
    $hash->{lastError} = $json->{error};
  }

  setKeyValue($hash->{NAME}."_accessToken",$json->{access_token});
  setKeyValue($hash->{NAME}."_refreshToken", $json->{refresh_token});

  if( $json->{access_token} ) {
    $hash->{STATE} = "Connected";

    ($hash->{expires_at}) = gettimeofday();
    $hash->{expires_at} += $json->{expires_in};

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "tokenExpiry", scalar localtime $hash->{expires_at});
    readingsEndUpdate($hash, 1);

    foreach my $key ( keys %defs ) {
      if ($defs{$key}->{TYPE} eq "HomeConnect") {
        fhem "set $key init";
      }
    }

    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$json->{expires_in}*3/4, 
      "HomeConnectConnection_RefreshTokenTimer", $hash, 0);
    return undef;
  } else {
    $hash->{STATE} = "Error";
  }
} 

#####################################
sub HomeConnectConnection_RefreshToken($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $conn = $hash->{hcconn};
  if (!defined $conn) {
    $conn = $hash;
  } else {
    $conn = $defs{$conn};
  }

  my ($gkerror, $refreshToken) = getKeyValue($conn->{NAME}."_refreshToken");
  if (!defined $refreshToken) {
    Log3 $name, 2, "$name: no token to be refreshed";
    return undef;
  }

  if( defined($conn->{expires_at}) ) {
    my ($seconds) = gettimeofday();
    if( $seconds < $conn->{expires_at} - 300 ) {
      Log3 $name, 2, "$name: no token refresh needed";
      return undef 
    }
  }

  my ($gterror, $gotToken) = getKeyValue($conn->{NAME}."_accessToken");

  my($err,$data) = HttpUtils_BlockingGet({
    url => "$hash->{api_uri}/security/oauth/token",
    timeout => 10,
    noshutdown => 1,
    data => {grant_type => 'refresh_token', 
	client_id => $conn->{client_id},  
	refresh_token => $refreshToken
    }
  });

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data ) {
    Log3 $name, 2, "$name: RefreshTokenResponse $data";

    $data =~ s/\n//g;
    if( $data !~ m/^{.*}$/m ) {

      Log3 $name, 2, "$name: invalid json detected: >>$data<<";

    } else {

      my $json = decode_json($data);

      if( $json->{error} ) {
        $hash->{lastError} = $json->{error};
      }

      setKeyValue($conn->{NAME}."_accessToken",$json->{access_token});

      if( $json->{access_token} ) {
        $conn->{STATE} = "Connected";
        $conn->{expires_at} = gettimeofday();
        $conn->{expires_at} += $json->{expires_in};
        undef $conn->{refreshFailCount};
        readingsBeginUpdate($conn);
        readingsBulkUpdate($conn, "tokenExpiry", scalar localtime $conn->{expires_at});
        readingsEndUpdate($conn, 1);
        RemoveInternalTimer($conn);
        InternalTimer(gettimeofday()+$json->{expires_in}*3/4, 
          "HomeConnectConnection_RefreshTokenTimer", $conn, 0);
        if (!$gotToken) {
          foreach my $key ( keys %defs ) {
            if ($defs{$key}->{TYPE} eq "HomeConnect") {
              fhem "set $key init";
            }
          }
        }
        return undef;
      }
    }
  }

  $conn->{STATE} = "Refresh Error" ;
  if (defined $conn->{refreshFailCount}) {
    $conn->{refreshFailCount} += 1;
    if ($conn->{refreshFailCount}==10) {
      Log 2,$conn->{NAME} . " refreshing token failed too many times, stopping";
      $conn->{STATE} = "Login necessary";
      setKeyValue($hash->{NAME}."_refreshToken", undef);
      return undef;
    }
  } else {
    $conn->{refreshFailCount} = 1;
  }
  RemoveInternalTimer($conn);
  InternalTimer(gettimeofday()+60, "HomeConnectConnection_RefreshTokenTimer", $conn, 0);
  return undef;
}

#####################################
sub HomeConnectConnection_AutocreateDevices
{
  my ($hash) = @_;

  #### Read list of appliances
  my $URL = "/api/homeappliances";

  my $applianceJson = HomeConnectConnection_request($hash,$URL);
  if (!defined $applianceJson) {
    return "Failed to connect to HomeConnectConnection API, see log for details";
  }

  my $appliances = decode_json ($applianceJson);

  for (my $i = 0; 1; $i++) {
    my $appliance = $appliances->{data}->{homeappliances}[$i];
    if (!defined $appliance) { last };
    if (!defined $defs{$appliance->{vib}}) {
      fhem ("define $appliance->{vib} HomeConnect $hash->{NAME} $appliance->{haId}");
    }
  }

  return undef;
}

#####################################
sub HomeConnectConnection_Undef($$)
{
   my ( $hash, $arg ) = @_;

   RemoveInternalTimer($hash);
   Log 3, "--- removed ---";
   return undef;
}

#####################################
sub HomeConnectConnection_Get($@)
{
  my ($hash, @args) = @_;

  return 'HomeConnectConnection_Get needs two arguments' if (@args != 2);

  my $get = $args[1];
  my $val = $hash->{Invalid};

  return "HomeConnectConnection_Get: no such reading: $get";

}

#####################################
sub HomeConnectConnection_RefreshTokenTimer($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log 2, "$name: refreshing token";

  undef $hash->{expires_at};
  HomeConnectConnection_RefreshToken($hash);
}

#####################################
sub HomeConnectConnection_request
{
  my ($hash, $URL) = @_;
  my $name = $hash->{NAME};
  
  my $api_uri = (defined $hash->{hcconn}) ? $defs{$hash->{hcconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log 3, "$name HomeConnectConnection request: $URL";

  HomeConnectConnection_RefreshToken($hash);

  my $conn = $hash->{hcconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/vnd.bsh.sdk.v1+json", "Authorization" => "Bearer $token" }
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    my $err_log = "Can't get $URL -- " . $err;
    Log 1, $err_log;
    return undef;
  }

  Log 3, "HomeConnectConnection response: " . $data;

  return $data;

}

#####################################
sub HomeConnectConnection_putrequest
{
  my ($hash, $URL, $put_data) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{hcconn}) ? $defs{$hash->{hcconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log 3, "HomeConnectConnection PUT request: $URL with data: $put_data";

  HomeConnectConnection_RefreshToken($hash);

  my $conn = $hash->{hcconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    method     => "PUT",
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/vnd.bsh.sdk.v1+json",
                    "Authorization" => "Bearer $token",
                    "Content-Type" => "application/vnd.bsh.sdk.v1+json"
                  },
    data       => $put_data
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    my $err_log = "Can't put $URL -- " . $err;
    Log 1, $err_log;
    return undef;
  }

  Log 3, "HomeConnectConnection PUT response: " . $data;

  return $data;

}

#####################################
sub HomeConnectConnection_delrequest
{
  my ($hash, $URL) = @_;
  my $name = $hash->{NAME};

  my $api_uri = (defined $hash->{hcconn}) ? $defs{$hash->{hcconn}}->{api_uri} : $hash->{api_uri};

  $URL = $api_uri . $URL;

  Log 3, "$name HomeConnectConnection DELETE request: $URL";

  HomeConnectConnection_RefreshToken($hash);

  my $conn = $hash->{hcconn};
  if (!defined $conn) {
    $conn = $name;
  }
  my ($gkerror, $token) = getKeyValue($conn."_accessToken");

  my $param = {
    url        => $URL,
    method     => "DELETE",
    hash       => $hash,
    timeout    => 3,
    noshutdown => 1,
    header     => { "Accept" => "application/vnd.bsh.sdk.v1+json", "Authorization" => "Bearer $token" }
  };

  my ($err, $data) = HttpUtils_BlockingGet($param);

  if ($err) {
    my $err_log = "Can't delete $URL -- " . $err;
    Log 1, $err_log;
    return undef;
  }

  Log 3, "HomeConnectConnection DELETE response: " . $data;

  return $data;

}


1;

=pod
=begin html

<a name="HomeConnectConnection"></a>
<h3>HomeConnectConnection</h3>
<ul>
  <a name="HomeConnectConnection_define"></a>
  <h4>Define</h4>
  <ul>
    <code>define &lt;name&gt; HomeConnectConnection &lt;api_key&gt; &lt;redirect_url&gt; [simulator]</code>
    <br/>
    <br/>
    Defines a connection and login to Home Connect Household appliances. See <a href="http://www.home-connect.com/">Home Connect</a> for details.<br>
    <br/>
    The following steps are needed to link FHEM to Home Connect:<br/>
    <ul>
      <li>Create a developer account at <a href="https://developer.home-connect.com/">Home Connect for Developers</a><br>
      <li>Create your Application under "My Applications", the REDIRECT-URL must be pointing to your local FHEM installation, e.g.<br>
      <code>http://localhost:8083/fhem?cmd.Test=set%20hcconn%20auth%20</code><br>
      <li>Make sure to include the rest of the URL as shown above. Then define the connection with your API Key and URL:<br>
      <code>define hcconn HomeConnectConnection API-KEY REDIRECT-URL [simulator]</code><br>
      <li>Click on the link "Home Connect Login" in the device and log in to your account. The simulator will not ask for any credentials.
      <li>Execute the set scanDevices action to create FHEM devices for your appliances.
    </ul>
    <br/>
	Currently, Home Connect API only supports the Simulator, no real Appliances. So the keyword <b>simulator</b> needs to be added to the definition.
    <br/>
	If your FHEM server does not run on localhost, please change the REDIRECT-URL accordingly
    <br/>
  </ul>
  <br>
  <a name="HomeConnectConnection_set"></a>
  <b>Set</b>
  <ul>
    <li>scanDevices<br>
      Start a device scan of the Home Connect account. The registered Home Connect devices are then created automatically
      in FHEM. The device scan can be started several times and will not duplicate devices as long as they have not been
      renamed in FHEM. You should change the alias attribute instead.
      </li>
    <li>refreshToken<br>
      Manually refresh the access token. This should be necessary only after internet connection problems.
      </li>
    <li>logout<br>
      Delete the access token and refresh tokens, and show the login link again.
      </li>
  </ul>
  <br>

</ul>

=end html
=cut
