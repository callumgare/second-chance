//
//  MainLogger.swift
//  GameWrapper
//
//  File-scope logger for main.swift's top-level functions. Lives outside
//  main.swift because top-level code there is eager: a logger declared at
//  file scope in main.swift would be constructed before main() gets a chance
//  to bootstrap the logging system. Here it is a lazy global, initialised on
//  first use — safely after bootstrap.

import Foundation
import Logging

nonisolated let mainLogger = Logger(label: "au.gare.callum.second-chance.GameWrapper.main")
