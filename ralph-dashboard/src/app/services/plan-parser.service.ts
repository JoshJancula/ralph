import { Injectable } from '@angular/core';

export interface ClassicTodo {
  type: 'classic';
  lineNumber: number;
  completed: boolean;
  content: string;
  fullBlock: string;
}

export interface YamlTodo {
  type: 'yaml';
  ordinal: number;
  id: string;
  content: string;
  status: string;
  verification: string;
  completed: boolean;
}

export type Todo = ClassicTodo | YamlTodo;

export interface PlanMetadata {
  name?: string;
  overview?: string;
  mode?: string;
  isProject?: boolean;
  planType?: 'leaf' | 'generated-control' | 'supplied' | 'workflow-derived';
}

export interface ParsedPlan {
  format: 'classic' | 'yaml';
  metadata: PlanMetadata;
  frontmatter?: Record<string, unknown>;
  todos: Todo[];
  completedCount: number;
  totalCount: number;
  rawContent: string;
}

@Injectable({
  providedIn: 'root',
})
export class PlanParserService {
  parsePlan(content: string): ParsedPlan {
    const format = this.detectFormat(content);
    const todos: Todo[] = [];
    let metadata: PlanMetadata = {};
    let frontmatter: Record<string, unknown> | undefined;

    if (format === 'yaml') {
      const parsed = this.parseYamlPlan(content);
      todos.push(...parsed.todos);
      metadata = parsed.metadata;
      frontmatter = parsed.frontmatter;
    } else {
      todos.push(...this.parseClassicPlan(content));
    }

    const completedCount = todos.filter((t) => t.completed).length;
    const totalCount = todos.length;

    return {
      format,
      metadata,
      frontmatter,
      todos,
      completedCount,
      totalCount,
      rawContent: content,
    };
  }

  private detectFormat(content: string): 'classic' | 'yaml' {
    const lines = content.split('\n');
    if (lines[0]?.trim() === '---') {
      for (let i = 1; i < lines.length; i++) {
        if (lines[i]?.trim() === '---') {
          return 'yaml';
        }
      }
    }
    return 'classic';
  }

  private parseYamlPlan(content: string): {
    todos: YamlTodo[];
    metadata: PlanMetadata;
    frontmatter: Record<string, unknown>;
  } {
    const todos: YamlTodo[] = [];
    const metadata: PlanMetadata = {};
    const frontmatter: Record<string, unknown> = {};

    const lines = content.split('\n');

    if (lines[0]?.trim() !== '---') {
      return { todos, metadata, frontmatter };
    }

    let endIdx = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i]?.trim() === '---') {
        endIdx = i;
        break;
      }
    }

    if (endIdx === -1) {
      return { todos, metadata, frontmatter };
    }

    const frontmatterContent = lines.slice(1, endIdx).join('\n');

    metadata.name = this.extractYamlField(frontmatterContent, 'name');
    metadata.overview = this.extractYamlField(frontmatterContent, 'overview');
    metadata.mode = this.extractYamlField(frontmatterContent, 'mode');
    const isProject = this.extractYamlField(frontmatterContent, 'isProject');
    metadata.isProject = isProject?.toLowerCase() === 'true';

    const todosSection = this.extractTodosSection(frontmatterContent);
    if (todosSection) {
      const parsedTodos = this.parseYamlTodos(todosSection);
      todos.push(...parsedTodos);
    }

    try {
      Object.assign(frontmatter, this.parseYamlObject(frontmatterContent));
    } catch {
      Object.assign(frontmatter, { raw: frontmatterContent });
    }

    return { todos, metadata, frontmatter };
  }

  private extractYamlField(content: string, fieldName: string): string | undefined {
    const regex = new RegExp(`^${fieldName}:\\s*(.*)$`, 'm');
    const match = content.match(regex);
    return match?.[1]?.trim();
  }

  private extractTodosSection(frontmatterContent: string): string {
    const lines = frontmatterContent.split('\n');
    let inTodos = false;
    const todoLines: string[] = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line) continue;

      if (line.trim() === 'todos:') {
        inTodos = true;
        continue;
      }

      if (inTodos) {
        if (line[0] && line[0] !== ' ' && line.trim() !== '') {
          break;
        }
        if (line.trim()) {
          todoLines.push(line);
        }
      }
    }

    return todoLines.join('\n');
  }

  private parseYamlTodos(todosSection: string): YamlTodo[] {
    const todos: YamlTodo[] = [];
    const lines = todosSection.split('\n');

    let currentTodo: Partial<YamlTodo> | null = null;
    let ordinal = 0;
    let pendingBlockField: 'content' | 'id' | 'status' | 'verification' | null = null;

    const assignField = (key: string, value: string): void => {
      if (!currentTodo) return;
      if (value.trim() === '|' || value.trim() === '|-' || value.trim() === '>' || value.trim() === '>-') {
        pendingBlockField = key === 'content' || key === 'id' || key === 'status' || key === 'verification' ? key : null;
        return;
      }
      pendingBlockField = null;
      if (key === 'content') {
        currentTodo.content = value;
      } else if (key === 'id') {
        currentTodo.id = value;
      } else if (key === 'status') {
        currentTodo.status = value;
      } else if (key === 'verification') {
        currentTodo.verification = value;
      }
    };

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      // A YAML block scalar (| or >) puts its value on the following, more-indented line(s).
      if (pendingBlockField && currentTodo && !line.match(/^\s+-\s+/) && !line.match(/^\s{4}\w+:/)) {
        assignField(pendingBlockField, trimmed);
        continue;
      }

      if (line.match(/^\s+-\s+/)) {
        if (currentTodo) {
          todos.push(this.completeTodo(currentTodo, ordinal));
        }
        ordinal++;
        currentTodo = { type: 'yaml', ordinal: ordinal + 1 } as YamlTodo;
        pendingBlockField = null;

        const match = line.match(/^\s+-\s+(\w+):\s*(.*)/);
        if (match) {
          assignField(match[1], match[2]);
        }
      } else if (currentTodo && line.match(/^\s{4}\w+:/)) {
        const match = line.match(/^\s{4}(\w+):\s*(.*)/);
        if (match) {
          assignField(match[1], match[2]);
        }
      }
    }

    if (currentTodo) {
      todos.push(this.completeTodo(currentTodo, ordinal));
    }

    return todos;
  }

  private completeTodo(partial: Partial<YamlTodo>, ordinal: number): YamlTodo {
    const status = partial.status ?? '';
    const completed = this.isStatusDone(status);

    return {
      type: 'yaml',
      ordinal: ordinal + 1,
      id: partial.id ?? '',
      content: partial.content ?? '',
      status: status,
      verification: partial.verification ?? '',
      completed,
    };
  }

  private isStatusDone(status: string): boolean {
    const normalized = status.toLowerCase().trim();
    return normalized === 'completed' || normalized === 'complete' || normalized === 'done';
  }

  private parseClassicPlan(content: string): ClassicTodo[] {
    const todos: ClassicTodo[] = [];
    const lines = content.split('\n');

    let i = 0;
    while (i < lines.length) {
      const line = lines[i];

      if (this.isClassicTodoLine(line)) {
        const completed = this.isClassicTodoCompleted(line);
        const lineContent = this.extractClassicTodoContent(line);

        let fullBlock = line;
        let j = i + 1;

        while (j < lines.length) {
          const nextLine = lines[j];

          if (this.isClassicTodoLine(nextLine)) {
            break;
          }
          if (nextLine.match(/^#{1,6}\s/) || nextLine.match(/^---\s*$/)) {
            break;
          }
          if (nextLine.trim().length > 0 && !nextLine.match(/^\s/)) {
            break;
          }

          fullBlock += '\n' + nextLine;
          j++;
        }

        todos.push({
          type: 'classic',
          lineNumber: i + 1,
          completed,
          content: lineContent,
          fullBlock,
        });

        i = j;
      } else {
        i++;
      }
    }

    return todos;
  }

  private isClassicTodoLine(line: string): boolean {
    return /^\s*-\s+\[\s*[\sx]\s*\]\s/i.test(line);
  }

  private isClassicTodoCompleted(line: string): boolean {
    return /^\s*-\s+\[x\]\s/i.test(line);
  }

  private extractClassicTodoContent(line: string): string {
    return line.replace(/^\s*-\s+\[\s*[\sx]\s*\]\s*/i, '').trim();
  }

  private parseYamlObject(content: string): Record<string, unknown> {
    const result: Record<string, unknown> = {};
    const lines = content.split('\n');

    for (const line of lines) {
      const match = line.match(/^(\w+):\s*(.*)/);
      if (match) {
        const key = match[1];
        const value = match[2].trim();
        result[key] = value;
      }
    }

    return result;
  }
}
