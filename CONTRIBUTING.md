# New Contributor's Survival Guide

This document details the steps and other important information on how to contribute to FreshPresence. Feel free to skip sections if you believe you're already set.

## Requirements:
- Basic knowledge of [Zig](https://ziglang.org/)
- Basic knowledge of the Discord RPC API

## Software prerequisites
- [Zig](https://ziglang.org)
- [Git](https://git-scm.com)
- Any text editor

# Preparing your system
In order to use Git you must set up your configuration, this should ideally match your GitHub account's name and email. 

You can use [GitHub Desktop](https://desktop.github.com) or the IDE of your choice to help you with this! **Or if you're more technically inclined**, follow the CLI instructions below.

This will modify the **global** config, which will allow you to contribute to multiple projects with the same name and email with ease.

`$ git config --global user.name Your Name`

`$ git config --global user.email you@example.com`

# Preparing your new development environment
It's almost time to clone FreshPresence! Create a fork by pressing the "Fork" button at the base of this repository.

Afterwards, open a terminal to your working directory and clone the new fork using Git.

This is usually done with the following command: 
`$ git@github.com:<YOUR_USERNAME>/FreshPresence.git`

Now, open the folder/workspace/solution with the IDE you chose. Explore the codebase, experiment, and have fun!

To run the software in **DEBUG** mode, simply write: 
`$ zig build run`

To compile for a specific platform, you can append `-Dtarget=TARGET` to the build invocation, eg. `zig build -Dtarget=x86_64-linux`

To compile a release build, you can append `-Doptimize=ReleaseSmall`. the possible options are `Debug`, `ReleaseSmall`, `ReleaseFast`, `ReleaseSafe`. Our builds are compiled with ReleaseSmall, but for test builds Debug or ReleaseSafe are preferred!

Make sure to add [the upstream FreshPresence repository](https://github.com/LittleBigRefresh/FreshPresence) as the "**upstream**" remote using your IDE or GitHub Desktop. Happy hunting!

### Follow up in the patching documentation for connecting using your choice of device, TBW