// swift-tools-version:4.0
//
//  Package.swift
//  WSServer
//
//  Created by zen on 7/1/19.
//  Copyright © 2019 AppSpector. All rights reserved.
//
import PackageDescription

let package = Package(
    name: "WSServer",

    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", 
                 from: "1.9.4"),
    ],

    targets: [
        .target(name: "WSServer", 
                dependencies: [
                  /* Add your target dependencies in here, e.g.: */
                  // "cows",
                  "NIO",
                  "NIOHTTP1",
                ])
    ]
)
