import defaultMdxComponents from "fumadocs-ui/mdx";
import type { MDXComponents } from "mdx/types";
import { Mermaid } from "@/components/mermaid";

export function getMDXComponents(components?: MDXComponents): MDXComponents {
  return {
    ...defaultMdxComponents,
    pre: ({ children, ...props }) => {
      const child = children as { props?: { className?: string; children?: string } };
      const className = child?.props?.className ?? "";

      if (className.includes("language-mermaid")) {
        return <Mermaid chart={String(child?.props?.children ?? "")} />;
      }

      const DefaultPre = defaultMdxComponents.pre!;
      return <DefaultPre {...props}>{children}</DefaultPre>;
    },
    ...components,
  };
}
