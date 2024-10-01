# SQLCipher 

This package provides a version of SQLite3 which can be encrypted. Database creation and loading uses
the same API as standard SQLite, but an extra command executed post-load both encrypts and decrypts the
underlying database:

```sqlite3
pragma key='mypassword';
```

Prior to executing this `pragma` SQLite will report that an encrypted database is not, in fact, a database.
Once the `pragma` has been executed and is successful, then subsequent SQLite commands will operate successfully.

### Sources

This package includes the constructed `sqlite3.[ch]` files resulting from a correct `./configure` invocation and `make`;
it doesn't contain the original source. To obtain the original source, look here:

https://www.zetetic.net/sqlcipher/

To compile the command line version of the database accessor, you'll need to build a copy of OpenSSL then modify the 
configure script:

```zsh
# build openSSL
cd myOpenSSLSources
,/configure
make
cd ../mySQLCipherSources
./configure --enable-tempstore=yes CFLAGS="-DSQLITE_HAS_CODEC -I../myOpenSSLSources" LDFLAGS="-lcrypto -L../myOpenSSLSources"
```

This assumes that you'd downloaded a recent OpenSSL alongside the code for SQLCipher.

### Adding This Package

This package makes use of several *so-called* unsafe build flags. As result, while I tag releases in the way a normal
Swift Package might be tagged, you can't make use of those version tags. You need to rely on an underlying commit hash
to link this to your project.

...sorry, I wish Apple wasn't so anal, or maybe I'm happy they are - I don't know enough to decide which...

### SQLCipher Good Citizenship

Be aware that while SQLCipher allows distribution of their code in both free and commercial code, ensure that you properly
credit them in your packages. I've added the same to this package - you should do this with your end-case code.

Also consider buying a license for this code if your app is wildly, or even moderately or lightly successful. I'm sure 
these folks have kids to feed like we all do!

## Community Edition Open Source License

Copyright (c) 2020, ZETETIC LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the ZETETIC LLC nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
