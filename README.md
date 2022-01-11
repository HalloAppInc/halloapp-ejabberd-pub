ejabberd HalloApp Edition
==========================
![Ejabberd CI](https://github.com/HalloAppInc/halloapp-ejabberd/workflows/Ejabberd%20CI/badge.svg) [![Hex version](https://img.shields.io/hexpm/v/ejabberd.svg "Hex version")](https://hex.pm/packages/ejabberd)

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
    export LDFLAGS="-L/usr/local/opt/openssl/lib"


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

### 3. Ejabberd Tests
Run the eunit tests:

    make eunit

Run a single module's eunit tests

    make eunit MODULE=<module_name>
where `<module_name>` is the module's name

Run the Common Tests:

    make ct

### 4. Running

Start Ejabberd on localhost, you don't need the `make install` to run ejabberd

    make run

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
