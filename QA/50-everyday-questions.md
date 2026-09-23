# Fifty everyday chat questions

Each question is tested as the first turn of a fresh Mira Orion session. The automated suite checks that Mira answers from its own records or opens a concrete next step, without an error. Subscription listing also checks the receipt and cancellation action.

In the simulator, open the chat's **•••** menu and choose **Add 50 chats**. Mira generates and saves these as separate conversations under **Conversations**. Opening the menu again offers **Open 50 chats** without duplicating them. Generating the collection uses isolated profile storage so actions in those chats do not change the active profile while the collection is built.

Simulator checks covered the subscription receipt and its fixed actions, cancellation and undo, the mixed-currency fee document, and the long affordability scenarios. These shared layouts cover the dense document forms; the automated suite checks all fifty first-turn reactions.

## Balances

1. Where is my money right now? — expected answer cue: `available`
2. How much do I have? — expected answer cue: `available`
3. Show my balances — expected answer cue: `available`
4. Show my holdings — expected answer cue: `available`

## Budget and reserve

5. How much is left in this week's budget? — expected answer cue: `left this week`
6. What's my weekly budget? — expected answer cue: `left this week`
7. Can I spend this week? — expected answer cue: `how much`
8. How much is my reserve? — expected answer cue: `reserve`

## Card controls

9. Freeze my card — expected answer cue: `frozen`
10. Is my card active? — expected answer cue: `card`
11. Open card controls — expected answer cue: `card`

## Receiving

12. How do I receive money? — expected answer cue: `receiving details`
13. Show my account details — expected answer cue: `receiving details`

## Subscriptions and renewals

14. Show all subscriptions — expected answer cue: `subscriptions`
15. How many subscriptions do I have? — expected answer cue: `subscriptions`
16. How much do my subscriptions cost each month? — expected answer cue: `subscriptions`
17. I need to save money from my subs — expected answer cue: `subscriptions`
18. Show my recurring charges — expected answer cue: `subscriptions`
19. When does Netflix renew? — expected answer cue: `netflix`
20. When does Spotify renew? — expected answer cue: `spotify`
21. What upcoming charges do I have? — expected answer cue: `charges`

## Fees and savings

22. What fees have I paid? — expected answer cue: `fee`
23. Where are my fees? — expected answer cue: `fee`
24. Find unused subscriptions — expected answer cue: `look at`
25. What am I still paying for that I don't use? — expected answer cue: `stopping`

## Offers and account tier

26. Show cashback — expected answer cue: `cashback`
27. What offers can I use? — expected answer cue: `offers`
28. What rewards do I have? — expected answer cue: `offers`
29. What tier am I on? — expected answer cue: `tier`
30. How do I upgrade my account? — expected answer cue: `tier`

## Goals and idle cash

31. Show my piggy banks — expected answer cue: `piggy`
32. How are my savings goals? — expected answer cue: `piggy banks`
33. How much is in my goal? — expected answer cue: `macbook pro`
34. How much is safe to put away? — expected answer cue: `safe`
35. Is there idle cash I could save? — expected answer cue: `safe`

## Shopping

36. Buy cat food — expected answer cue: `price`
37. Purchase headphones — expected answer cue: `price`
38. Buy a book — expected answer cue: `price`
39. Buy running shoes — expected answer cue: `price`

## Transfers

40. Send money — expected answer cue: `who`
41. Transfer money to a friend — expected answer cue: `who`
42. Send USD 25 to a contact — expected answer cue: `who`

## Other money desk tasks

43. Show my splits — expected answer cue: `splits`
44. Split USD 120 with Ana and Rui — expected answer cue: `split`
45. Can I afford USD 80? — expected answer cue: `plan`
46. Is there an unknown charge? — expected answer cue: `charge`
47. Can you negotiate my contract? — expected answer cue: `renewal`
48. What's my credit card utilization? — expected answer cue: `limit`
49. What if my package is damaged? — expected answer cue: `damaged`
50. What can you actually do? — expected answer cue: `simulated`

## Agentic task routes checked separately

The task service's 97 focused tests passed. They exercise these additional first requests and their follow-up state without depending on a live search result:

- “Find me running shoes size 43 under 120 euros” → shopping task with product and budget.
- “Flight to Lisbon under 500 euros” → travel task with a budget.
- “Find me a flight to São Paulo” → asks for the missing departure and dates.
- “Find me a restaurant in São Paulo for 4 on Friday at 8pm” → restaurant task.
- “I need to buy lunch” → asks whether to deliver it or find a table.
- “Watch the price of the Brooks Ghost 15 under 100 dollars every day” → standing price watch.
- “Research the best espresso machines” → research task with a saved result artifact.
- “Reserve a table for two in Lisbon” → restaurant task.
