An app for running the pre-unity Nancy Drew video games on modern Macs. It (should hopefully) work for all the Nancy Drew games before "Midnight in Salem".

<p align="center">
    <img
        alt="Logo for Second Chance app - a black silhouette of Nancy Drew on a plain brown background" 
        src="https://github.com/callumgare/second-chance/raw/refs/heads/main/docs/SecondChanceIcon.png"
        style="width: 200px"
    />
</p>

> [!WARNING]
> This project is still very new and there will be bugs. I've tried to make it as user friendly as possible but keep in mind there are still some rough edges. Please let me know if you run into any issues using it.

Want to play the Nancy Drew adventure games but you own a Mac and can't get them to run?  That's where Second Chance
comes in. You tell it where to find your copy of one of the Nancy Drew games and it will create a playable version of
the game as a new app. Currently it only works with the CD versions of the games but in the near future I hope to support running via Steam
or copies directly downloaded from the Her Interactive website.


## Using Second Chance

You can download the [latest version of Second Chance
here](https://github.com/callumgare/second-chance/releases/latest).

> [!IMPORTANT]
> I'm too cheep to pay for an Apple developer membership ($99 USD a year). This means macOS will give some some scary
> warnings when you try to open it for the first time. I pinky promise there's nothing sneaky happening (and if you're technical you
> can inspect the source code for the app in this repo).

In the most recent versions of macOS you'll likely see a warning like this on first run. Select **Done**.
![First warning screen](./docs/first-warning.png)

Now you need to open **Privacy & Security** in **System Settings**. If you scroll down to near the bottom you should
see a section that says:
> "Second Chance" was blocked to protect your Mac. [Open Anyway]

![privacy settings](./docs/settings.png)

Click **Open Anyway**. You'll probably then see a final warning that looks like this:
![last warning](./docs/second-warning.png)

Click **Open Anyway** again to continue. macOS may then ask for your password to confirm.

Finally after all that you should see a screen like this:
![main second chance screen](./docs/main-screen.png)

Once you've loaded your CD copy of any of the classic games you can select "Game Disk(s)" and point to the CD. From
there Second Chance will create a new app for that game. When done it'll ask you where you want to save it. From that
point on you can just simply open the app it created in to be able to play the game.

Have fun!

---

## Architecture / Code History
I have many fond memories of whiling away my childhood scoping out old mansions and questioning shady characters.
So a couple of years back I decided to play though them again. However getting them to run on modern mac hardware ended
up being quite a process. I found there was limited information online, mostly buried in various forum threads and much
of which is now outdated.

Over time I pieced together the different set of tweaks and hacks required to get each game to run. To make running them
a bit easier I started a (then simple) bash script to help automate the creation of a Wine wrapper for some of the
games. Over time the scope and complexity grew and grew and it ballooned into something way bigger than a shell scripts
should be used for. I did my best to keep it organised in a readable way but it was quite brittle and didn't have good
prospects for long-term maintainability.

I'd never written any swift before otherwise I probably would have switched to building it as a proper Mac app a lot
earlier when doing such a port would have been a lot more straightforward. However with with heavy use of Claude I ended
up migrating it. The code is pretty terrible to be honest but my main focus was just getting it working. I hope to clean
that up over time.

There's 2 main components, the game wrapper app and the second chance app.

### The Game Wrapper App
This acts as a container which is responsible for running the game. It includes everything necessary to run the game
except for the game files themselves until the user uses Second Chance install the game into a copy of the Game Wrapper app.

### The Second Chance App
This provides a user interface for taking the game installer files and installing them inside a copy of the wrapper app.

## Testing

### Quick Start
```bash
# Run fast unit tests (~5 seconds)
./run-tests.sh unit

# Test one specific game
./run-tests.sh quick scarlet-hand

# Test all games (takes a bit over an hour and will regularly bring a full screen window to the front)
./run-tests.sh integration
```

## Development

Good luck (and also thank you very much for considering helping out).

### Prerequisites

- **Xcode** (16 or later) — provides `xcodebuild`, Swift 5.0, and macOS SDK
- **Homebrew** packages:
  ```bash
  brew install xcbeautify xctesthtmlreport
  ```
  `xcbeautify` pretty-prints build/test output; `xctest-html-report` generates HTML test reports.

All other dependencies (Wine, ScummVM, winetricks, AutoIt, exiftool) are automatically downloaded and cached in `~/Library/Caches/SecondChance/` during the build process — you don't need to install them yourself.


## Built with
- [wine](https://www.winehq.org/)
- [cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) - I couldn't seem to get the games to run with the builtin wine
  DirectX implementation but cnc-ddraw seems to fix that.
- [ScummVM](https://www.scummvm.org/) - Currently ScummVM just supports some of the earlier games but support more games
  is being actively worked on.
