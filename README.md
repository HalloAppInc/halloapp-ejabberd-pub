ejabberd Community Edition
==========================

![Ejabberd CI](https://github.com/HalloAppInc/halloapp-ejabberd/workflows/Ejabberd%20CI/badge.svg) [![Hex version](https://img.shields.io/hexpm/v/ejabberd.svg "Hex version")](https://hex.pm/packages/ejabberd)



ejabberd is a distributed, fault-tolerant technology that allows the creation
of large-scale instant messaging applications. The server can reliably support
thousands of simultaneous users on a single node and has been designed to
provide exceptional standards of fault tolerance. As an open source
technology, based on industry-standards, ejabberd can be used to build bespoke
solutions very cost effectively.


Key Features
------------

- **Cross-platform**  
  ejabberd runs under Microsoft Windows and Unix-derived systems such as
  Linux, FreeBSD and NetBSD.

- **Distributed**  
  You can run ejabberd on a cluster of machines and all of them will serve the
  same XMPP domain(s). When you need more capacity you can simply add a new
  cheap node to your cluster. Accordingly, you do not need to buy an expensive
  high-end machine to support tens of thousands concurrent users.

- **Fault-tolerant**  
  You can deploy an ejabberd cluster so that all the information required for
  a properly working service will be replicated permanently on all nodes. This
  means that if one of the nodes crashes, the others will continue working
  without disruption. In addition, nodes also can be added or replaced ‘on
  the fly’.

- **Administrator-friendly**  
  ejabberd is built on top of the Open Source Erlang. As a result you do not
  need to install an external database, an external web server, amongst others
  because everything is already included, and ready to run out of the box.
  Other administrator benefits include:
  - Comprehensive documentation.
  - Straightforward installers for Linux and Mac OS X.
  - Web administration.
  - Shared roster groups.
  - Command line administration tool.
  - Can integrate with existing authentication mechanisms.
  - Capability to send announce messages.

- **Internationalized**  
  ejabberd leads in internationalization. Hence it is very well suited in a
  globalized world. Related features are:
  - Translated to 25 languages.
  - Support for IDNA.

- **Open Standards**  
  ejabberd is the first Open Source Jabber server claiming to fully comply to
  the XMPP standard.
  - Fully XMPP-compliant.
  - XML-based protocol.
  - Many protocols supported.


Additional Features
-------------------

Moreover, ejabberd comes with a wide range of other state-of-the-art features:

- **Modularity**
  - Load only the modules you want.
  - Extend ejabberd with your own custom modules.

- **Security**
  - SASL and STARTTLS for c2s and s2s connections.
  - STARTTLS and Dialback s2s connections.
  - Web Admin accessible via HTTPS secure access.

- **Databases**
  - Internal database for fast deployment (Mnesia).
  - Native MySQL support.
  - Native PostgreSQL support.
  - ODBC data storage support.
  - Microsoft SQL Server support.

- **Authentication**
  - Internal authentication.
  - PAM, LDAP and ODBC.
  - External authentication script.

- **Others**
  - Support for virtual hosting.
  - Compressing XML streams with Stream Compression (XEP-0138).
  - Statistics via Statistics Gathering (XEP-0039).
  - IPv6 support both for c2s and s2s connections.
  - Multi-User Chat module with support for clustering and HTML logging.
  - Users Directory based on users vCards.
  - Publish-Subscribe component with support for Personal Eventing.
  - Support for web clients: HTTP Polling and HTTP Binding (BOSH).
  - Component support: interface with networks such as AIM, ICQ and MSN.


Quickstart guide
----------------

### 0. Requirements

To compile ejabberd you need:

 - GNU Make.
 - GCC.
 - Libexpat ≥ 1.95.
 - Libyaml ≥ 0.1.4.
 - Erlang/OTP ≥ 19.1.
 - OpenSSL ≥ 1.0.0.
 - Zlib ≥ 1.2.3, for Stream Compression support (XEP-0138). Optional.
 - ImageMagick's Convert program and Ghostscript fonts. Optional. For CAPTCHA
   challenges.

If your system splits packages in libraries and development headers, you must
install the development packages also.

### 1. Compile and install on *nix systems

To compile ejabberd, execute the following commands.  The first one is only
necessary if your source tree didn't come with a `configure` script (In this
case you need autoconf installed).

    ./autogen.sh
    ./configure
    make

To install ejabberd, run this command with system administrator rights (root
user):

    sudo make install

These commands will:

- Install the configuration files in `/etc/ejabberd/`
- Install ejabberd binary, header and runtime files in `/lib/ejabberd/`
- Install the administration script: `/sbin/ejabberdctl`
- Install ejabberd documentation in `/share/doc/ejabberd/`
- Create a spool directory: `/var/lib/ejabberd/`
- Create a directory for log files: `/var/log/ejabberd/`


### 2. Start ejabberd

You can use the `ejabberdctl` command line administration script to
start and stop ejabberd. For example:

    ejabberdctl start

For detailed information please refer to the ejabberd Installation and
Operation Guide available online and in the `doc` directory of the source
tarball.


Development
-----------

### 0. Erlang

##### On Mac

Install Erlang 23

    brew install erlang@23

In terminal, enter `erl` to see whether erlang works fine. If not, run
`vi ~/.zshrc` and modify the content to be

`export PATH=/usr/local/opt/erlang@23/bin:$PATH`. Use `source ~/.zshrc` to run the updated script.

##### On Linux
Install Erlang 23
    
    # before you install erlang 23, install libraries
    sudo apt install autoconf libssl-dev libncurses5-dev
    sudo apt install openjdk-11-jdk unixodbc-dev build-essential libwxbase3.0-dev libwxgtk3.0-dev

    # Download erlang
    wget https://github.com/erlang/otp/archive/refs/tags/OTP-23.3.4.1.zip
    #unzip the code and go to the folder
    ./configure
    make
    sudo make install

    # check if erlang installed 
    erl

### 1. Redis

You need to get a redis cluster running on your local machine to run ejabberd localy
and also to run the tests. Follow these steps

    git clone https://github.com/antirez/redis.git
    cd redis
    make
    sudo make install
    cd utils/create-cluster
    ./create-cluster start
    ./create-cluster create

After the initial setup next time you will just need to do

    cd utils/create-cluster
    ./create-cluster start


### 2. Compiling Ejabberd
Clone the repository using SSH instead of HTTPS. To generate the SSH key can refer to this
[link](https://help.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh)

##### On Mac

Configure ejabberd to use custom OpenSSL, Yaml, iconv. [Resource](https://docs.ejabberd.im/admin/installation/#macos).

    brew install git elixir openssl expat libyaml libiconv libgd sqlite rebar rebar3 automake autoconf libsodium
    export CFLAGS="-I/usr/local/opt/openssl/include -I/usr/local/include -I/usr/local/opt/expat/include"
    export CPPFLAGS="-I/usr/local/opt/openssl/include/ -I/usr/local/include -I/usr/local/opt/expat/include"


##### On Linux
Install dependencies:

    sudo apt install libexpat1-dev libyaml-dev zlib1g-dev libsodium-dev

##### On both Mac and Linux
Run following commands to compile ejabberd

    ./autogen.sh
    ./configure 
    make 

    # optionally install to get ejabberdctl to work
    sudo make install

__Note (Mac)__:
The above will likely not work right off the bat. A bandaid solution until the `configure.ac` file is modified is the following:
1. Set `export LDFLAGS="-L/usr/local/opt/openssl/lib"` along with setting the other flags as above.
2. Immediately after running `./configure` and before running `make`, `unset LDFLAGS`


### 3. Ejabberd Tests
Run the eunit tests:

    HALLO_ENV=test ./rebar eunit

Run the Common Tests:

    HALLO_ENV=test ./rebar ct suites=ha

### 4. Running

Start Ejabberd on localhost, you don't need the `make install` to run ejabberd

    HALLO_ENV=localhost EJABBERD_CONFIG_PATH=ejabberd.yml erl -kernel shell_history enabled -pa ebin -pa deps/*/ebin -s ejabberd

### 5. AWS 
Make sure to install AWS CLI https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-mac.html#cliv2-mac-install-cmd:

On MacOS:

    curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
    sudo installer -pkg AWSCLIV2.pkg -target /

Set configurations:

    aws configure
    AWS Access Key ID: (given separately)
    AWS Secret Access Key: (given separately)
    Default region name: us-east-1
    Default output format: (press enter)


Links
-----

- Documentation: https://docs.ejabberd.im
- Community site: https://www.ejabberd.im
- ejabberd commercial offering and support: https://www.process-one.net/en/ejabberd
