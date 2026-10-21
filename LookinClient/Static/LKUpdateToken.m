//
//  LKUpdateToken.m
//  LookinClient
//
//  Created by huangj on 2026/10/21.
//

#import "LKUpdateToken.h"

@implementation LKUpdateToken {
    NSUInteger _currentGeneration;
}

- (NSUInteger)currentGeneration {
    return _currentGeneration;
}

- (void)invalidate {
    _currentGeneration += 1;
}

- (BOOL)isCurrent:(NSUInteger)generation {
    return generation == _currentGeneration;
}

@end
