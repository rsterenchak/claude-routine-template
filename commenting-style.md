# Commenting style

Code written for this coursework repo is heavily commented, in the style below.
This is a required convention — match it on every source file you write or edit.
The reference example is C/C++ (the style's origin); **adapt the syntax to the
assignment's language while keeping the density and structure identical.**

## File header

Every source file opens with a block-comment header containing, in order:

- A prose paragraph describing what the program does and how the user interacts
  with it — a few sentences, not a one-liner.
- A blank line.
- Two lines: the author (`Robert Sterenchak`) and the date.

Use whatever header comment form is idiomatic for the language — a `/* */` block
in C/C++/C#/Java, a module docstring in Python — but keep all three pieces. Do
not add a course name, assignment number, or any field not listed above.

## Comment every function / method

A one-line block comment sits directly above every function, method, or
constructor, phrased as a plain statement of what it does — "This function …",
"Constructor …", "Set function …", "Get function …".

## Comment declarations and key statements inline

Trailing comments on variable declarations and on nearly every meaningful
statement — terse, lowercase, describing what the line does:

- declarations: `int index = 0;//initial integer value`
- operations:   `a[index]++;//increments array value at specified position`
- conditionals: `if (c >= 'A' && c <= 'Z') {//checks if letter is uppercase`

## Comment above loops and control blocks

A block comment above each loop and significant control block stating its
purpose: `/*Ensures input does not end until the user gives the command.*/`

## Mark the end of every block

Annotate closing braces with what they close — `}//end of main`,
`}//end of function`, `}//end while loop`, `}//ends copy constructor`. This
applies to functions, loops, and other notable blocks. In brace-less languages
(Python) this one drops away naturally; every other rule still applies.

## Overall

Near-exhaustive. Almost every line of substance carries an annotation — when in
doubt, comment it. The goal is clarity for a reader following the logic line by
line, not brevity.

## Reference (C)

```c
/*
 * This program counts the letters of the alphabet in text the user types or
 * redirects from a file, printing each letter's count once the user signals EOF.
 *
 * Robert Sterenchak
 * October 14, 2019
 */
#include <stdio.h>

#define SIZE 26  /*array size, one slot per letter*/

void printInstructions(void);//prints initial instructions to user

/*Main function where the program's functions are called in order.*/
int main(){
  int letters[SIZE] = {0};//counts, one per letter, all initially zero
  printInstructions();//function 1
  return 0;
}//end of main

/*This function prints initial instructions to the user.*/
void printInstructions(void){
  printf("This program counts the letters of the alphabet.\n");//user instructions
}//end of function
```
