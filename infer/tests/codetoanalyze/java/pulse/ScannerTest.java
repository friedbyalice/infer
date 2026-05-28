/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
package codetoanalyze.java.infer;

import java.util.Scanner;
import java.util.regex.Pattern;

class ScannerTest {
  void nextDouble_ok() {
    Scanner scanner = new Scanner("42.0");
    double d = scanner.nextDouble();
  }

  void nextPattern_ok() {
    Scanner scanner = new Scanner("hello world");
    String s = scanner.next(Pattern.compile("[a-z]+"));
  }

  void hasNextPattern_ok() {
    Scanner scanner = new Scanner("hello world");
    boolean b = scanner.hasNext(Pattern.compile("[a-z]+"));
  }
}
