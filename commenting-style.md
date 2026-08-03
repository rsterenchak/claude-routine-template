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

The header describes WHAT the file does and WHY it exists. Decisions about
specific lines — why a comparison is inclusive, why one filter is explicit
rather than incidental — belong in the inline comment on that line, where the
reader meets them. Do not explain a line in the header and again beside it.

## Comment every function / method

A one-line block comment sits directly above every function, method, or
constructor, phrased as a plain statement of what it does — "This function …",
"Constructor …", "Set function …", "Get function …".

## Single-unit files: header only, no second block

The three comment layers below assume three different scopes: the header
describes the FILE, the block above a function describes THAT FUNCTION, and
inline comments describe LINES. When a file contains exactly one top-level unit
— a single SQL query, a lone exported function, one class with no siblings —
the first two scopes collapse onto the same thing, and writing both produces the
same explanation twice at length.

In that case write the HEADER ONLY and go straight to the code. Do not add a
block comment above the single unit restating it. Every other rule still
applies: inline comments on declarations and meaningful statements, block
comments above loops and control blocks INSIDE the unit, and end-of-block
annotations.

A file with two or more top-level units is the normal case and keeps both
layers — each unit gets its own one-line block comment, because now they
describe different things.

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

## Reference (single-unit file — SQL)

Two or more top-level units, as in the C example above, keep both comment
layers. This file has one, so the header carries the description and the query
follows it directly — no second block restating the same thing.

```sql
/*
 * This file holds the weekly overdue report for the interlibrary loan tracker:
 * the query the loan desk runs to see which borrowed items are late, so it can
 * chase them before a patron is charged a fee. It reads the requests table
 * (schema.sql), joining patrons for the borrower's name and branches for the
 * lending branch; run seed.sql first to see it against real rows.
 *
 * Robert Sterenchak
 * August 1, 2026
 */

SELECT p.name                     AS patron_name,     -- the patron holding the overdue item
       r.title                    AS title,           -- the title of the overdue item
       b.name                     AS lending_branch,  -- the branch handling this loan
       CURRENT_DATE - r.due_date  AS days_overdue     -- whole days past due; zero on the day it is due
FROM requests AS r                                    -- the loan requests being reported on
JOIN patrons  AS p ON p.id = r.patron_id              -- resolve the patron's name
JOIN branches AS b ON b.id = r.requesting_branch_id   -- resolve the branch name
WHERE r.state <> 'returned'                           -- exclude requests already returned
  AND r.state <> 'cancelled'                          -- explicit, not relying on a cancelled request's NULL due_date
  AND r.due_date <= CURRENT_DATE                      -- inclusive: keep items due today as well as before today
ORDER BY days_overdue DESC;                           -- most overdue first so the desk works the worst cases first
```
