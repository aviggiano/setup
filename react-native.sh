#!/usr/bin/env bash

ANDROID_STUDIO_URL="https://dl.google.com/dl/android/studio/ide-zips/2.3.0.8/android-studio-ide-162.3764568-linux.zip"

# http://facebook.github.io/react-native/docs/getting-started.html
## 1
npm install -g react-native-cli

# https://developer.android.com/studio/index.html
cd ~/Documents
wget "$ANDROID_STUDIO_URL" -O android-studio.zip
unzip android-studio.zip
rm android-studio.zip
cd android-studio/bin
sudo ln -s $(pwd)/studio.sh /usr/bin/android-studio 

# https://developer.android.com/studio/install.html
sudo apt-get install libc6:i386 libncurses5:i386 libstdc++6:i386 lib32z1 libbz2-1.0:i386

## 2
## 3
## 4
echo "export ANDROID_HOME=\${HOME}/Android/Sdk" >> ~/.bash_custom
echo "export PATH=\${PATH}:\${ANDROID_HOME}/tools" >> ~/.bash_custom
echo "export PATH=\${PATH}:\${ANDROID_HOME}/platform-tools" >> ~/.bash_custom
