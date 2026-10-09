```c title="a.c" {2} lineNumbers
int a = 1;
/* spans
lines */

int b = 2;
```

```diff
@@ x @@
-old
+new
 same
```

```text {1-2,4}
one
two
three
four
```

:::code-group
```sh title="Unix"
ls
```
```bat
dir
```
:::

::::tabs
:::tab First
One.
:::
:::tab
Two.
:::
Ignored text.
::::
